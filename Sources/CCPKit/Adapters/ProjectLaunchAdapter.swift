// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import Foundation
import Observation

/// One thing the Projects widget can launch inside a checkout.
public struct ProjectTarget: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable, Equatable, Codable {
        /// The harness board (`scripts/dashboard.py up`).
        case board
        /// A `[[task]]` entry from the checkout's `dashboard.toml`.
        case task
        /// A `package.json` dev/start script.
        case devServer
        /// A known entry-point script (`app.sh`, `mac.sh`, `ios.sh`) that
        /// builds/installs and launches the app.
        case build
    }

    /// How the target's URL resolves, if it serves one at all.
    public enum URLKind: String, Sendable, Equatable, Codable {
        /// Resolves through the checkout's `.claude/launch.json`, the same
        /// claim the harness board publishes.
        case board
        case none
    }

    /// Stable across launches: the project directory plus the target name, so
    /// `lastRunAt` survives rediscovery.
    public let id: String
    public let projectRoot: String
    public let projectName: String
    public let name: String
    public let label: String
    public let kind: Kind
    public let command: [String]
    public let urlKind: URLKind
    /// The toml `busy` text, drawn while the target transitions.
    public let busy: String?
    public var lastRunAt: Date?

    public init(id: String, projectRoot: String, projectName: String, name: String,
                label: String, kind: Kind, command: [String], urlKind: URLKind,
                busy: String? = nil, lastRunAt: Date? = nil) {
        self.id = id
        self.projectRoot = projectRoot
        self.projectName = projectName
        self.name = name
        self.label = label
        self.kind = kind
        self.command = command
        self.urlKind = urlKind
        self.busy = busy
        self.lastRunAt = lastRunAt
    }
}

/// One discovered checkout and its launchable targets, the latter sorted
/// most-recently-run first with never-run targets last.
public struct DiscoveredProject: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let rootPath: String
    /// The `[project] name` from the checkout's `dashboard.toml`, when one is set.
    public let displayName: String?
    public let targets: [ProjectTarget]

    public init(name: String, rootPath: String, displayName: String? = nil, targets: [ProjectTarget]) {
        self.id = rootPath
        self.name = name
        self.rootPath = rootPath
        self.displayName = displayName
        self.targets = targets
    }
}

/// What a target run came to. Board URLs ride the outcome back to the
/// view, which opens them — the adapter itself never opens anything.
public enum ProjectLaunchOutcome: Sendable, Equatable {
    /// A process was spawned, or a board brought up; the board URL when
    /// there is one, nil for plain processes.
    case started(URL?)
    /// The board was already serving; nothing was spawned.
    case alreadyRunning(URL)
    case failed

    public var url: URL? {
        switch self {
        case .started(let url): return url
        case .alreadyRunning(let url): return url
        case .failed: return nil
        }
    }
}

public enum ProjectTargetStatus: Sendable, Equatable {
    case running
    case stopped
}

/// One `~/dev` entry the discovery scan considers.
public struct ProjectDevEntry: Sendable, Equatable {
    public let name: String
    public let rootPath: String
    public let modifiedAt: Date

    public init(name: String, rootPath: String, modifiedAt: Date) {
        self.name = name
        self.rootPath = rootPath
        self.modifiedAt = modifiedAt
    }
}

// MARK: - Source

/// The seam a test stands a fake in for: the filesystem scan, process
/// spawning/signalling, and board probing are not things a test triggers.
public protocol ProjectLaunchSource: AnyObject, Sendable {
    // Discovery filesystem.
    func devEntries() -> [ProjectDevEntry]
    func fileExists(atPath path: String) -> Bool
    func fileContents(atPath path: String) -> Data?
    // Processes.
    func spawn(command: [String], workingDirectory: String, logPath: String) -> Int32?
    func isPidAlive(_ pid: Int32) -> Bool
    func terminate(_ pid: Int32)
    func kill(_ pid: Int32)
    // Boards (harness semantics, shared with `HarnessDashboardSource`).
    func runningBoardURL(rootPath: String) async -> URL?
    func boardUp(rootPath: String) async -> HarnessDashboardOutcome
    func boardDown(rootPath: String) async
    func open(_ url: URL) async
    // Environment.
    func logDirectory() -> URL
    func now() -> Date
}

/// The real one: `~/dev` on disk, `Process` children, the checkout's
/// `scripts/dashboard.py`.
// @unchecked Sendable: the lock guards the retained processes; boards is Sendable.
public final class LiveProjectLaunchSource: ProjectLaunchSource, @unchecked Sendable {
    private let boards: LiveHarnessDashboardSource
    private let lock = NSLock()
    /// Retained while their children run, so the log handles behind
    /// `standardOutput`/`standardError` stay open and `terminate()` has a
    /// handle to signal through. The exit handler reaps each entry, so
    /// nothing lingers past its child.
    private var processes: [Int32: (process: Process, handle: FileHandle)] = [:]

    public init(
        browserOpener: any BoardBrowserOpener = LiveArcBoardOpener(),
        fallbackOpen: @escaping @Sendable (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.boards = LiveHarnessDashboardSource(browserOpener: browserOpener, fallbackOpen: fallbackOpen)
    }

    public func devEntries() -> [ProjectDevEntry] {
        let dev = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev")
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dev, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])
        else { return [] }
        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  !url.lastPathComponent.hasPrefix("."),
                  let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return nil }
            return ProjectDevEntry(name: url.lastPathComponent, rootPath: url.path, modifiedAt: mtime)
        }
    }

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func fileContents(atPath path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Starts the command detached: stdin is null, stdout/stderr append to
    /// the per-target log, and this returns the pid without waiting for
    /// exit. Nil when the process would not start.
    public func spawn(command: [String], workingDirectory: String, logPath: String) -> Int32? {
        guard !command.isEmpty else { return nil }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: logPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: logPath) else { return nil }
        handle.seekToEndOfFile()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
        } catch {
            try? handle.close()
            return nil
        }
        let pid = process.processIdentifier
        process.terminationHandler = { [weak self] exited in
            self?.reap(pid: exited.processIdentifier)
        }
        lock.withLock { processes[pid] = (process, handle) }
        return pid
    }

    /// Drops the retained entry and closes its log handle; safe to call
    /// twice, since the exit handler and `kill` can race.
    private func reap(pid: Int32) {
        let handle = lock.withLock { processes.removeValue(forKey: pid)?.handle }
        try? handle?.close()
    }

    /// Alive only while a retained child is still running: a pid we no
    /// longer hold (reaped, or never ours) reads as dead, so a recycled
    /// pid can never report another process as ours.
    public func isPidAlive(_ pid: Int32) -> Bool {
        lock.withLock { processes[pid]?.process.isRunning } ?? false
    }

    public func terminate(_ pid: Int32) {
        let process = lock.withLock { processes[pid]?.process }
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    public func kill(_ pid: Int32) {
        guard lock.withLock({ processes[pid] }) != nil else { return }
        Darwin.kill(pid, SIGKILL)
        reap(pid: pid)
    }

    public func runningBoardURL(rootPath: String) async -> URL? {
        await boards.runningURL(rootPath: rootPath)
    }

    public func boardUp(rootPath: String) async -> HarnessDashboardOutcome {
        await boards.runUp(rootPath: rootPath)
    }

    public func boardDown(rootPath: String) async {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "scripts/dashboard.py", "down"]
            process.currentDirectoryURL = URL(fileURLWithPath: rootPath)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }.value
    }

    public func open(_ url: URL) async {
        await boards.open(url)
    }

    public func logDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ControlCenterPro/logs")
    }

    public func now() -> Date {
        Date()
    }
}

// MARK: - Adapter

/// The Projects widget's model: discovered checkouts, background runs, and
/// per-target status.
///
/// Discovery is a pure function of what the source reports; runs never block
/// (spawn records pid + `lastRunAt` and returns); board taps reuse the
/// serving URL without spawning. A tap reuses the same busy guard as
/// `HarnessDashboardAdapter` so a second tap cannot stack servers.
@MainActor
@Observable
public final class ProjectLaunchAdapter {
    static let lastRunDefaultsKey = "ccp.projectLaunch.lastRunAt.v1"
    static let maxProjects = 10
    /// Known entry-point scripts, in the order their targets list.
    static let entryScripts = ["app.sh", "mac.sh", "ios.sh"]

    public private(set) var projects: [DiscoveredProject] = []
    public private(set) var pids: [String: Int32] = [:]
    public private(set) var busyIDs: Set<String> = []

    @ObservationIgnored private let source: ProjectLaunchSource
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let stopGraceInterval: TimeInterval
    @ObservationIgnored private var lastRuns: [String: Date]

    public convenience init() {
        self.init(source: LiveProjectLaunchSource())
    }

    public init(source: ProjectLaunchSource, defaults: UserDefaults = .standard,
                stopGraceInterval: TimeInterval = 2) {
        self.source = source
        self.defaults = defaults
        self.stopGraceInterval = stopGraceInterval
        self.lastRuns = Self.loadLastRuns(from: defaults)
    }

    public func isBusy(_ target: ProjectTarget) -> Bool {
        busyIDs.contains(target.id)
    }

    public func pid(for target: ProjectTarget) -> Int32? {
        pids[target.id]
    }

    public func lastRunAt(for target: ProjectTarget) -> Date? {
        lastRuns[target.id]
    }

    // MARK: Discovery

    /// Rescans `~/dev`: the ten most recently modified checkouts, each with
    /// its launchable targets sorted most-recently-run first. The scan and
    /// file reads run off the main thread; only the publish lands here.
    public func discover() async {
        let source = self.source
        let lastRuns = self.lastRuns
        let maxProjects = Self.maxProjects
        let projects = await Task.detached(priority: .userInitiated) {
            Self.scan(source: source, lastRuns: lastRuns, maxProjects: maxProjects)
        }.value
        self.projects = projects
    }

    nonisolated static func scan(
        source: ProjectLaunchSource, lastRuns: [String: Date], maxProjects: Int
    ) -> [DiscoveredProject] {
        let entries = source.devEntries()
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maxProjects)
        return entries.map { entry in
            DiscoveredProject(
                name: entry.name, rootPath: entry.rootPath,
                displayName: displayName(name: entry.name, rootPath: entry.rootPath, source: source),
                targets: sortTargets(buildTargets(
                    name: entry.name, rootPath: entry.rootPath,
                    source: source, lastRuns: lastRuns)))
        }
    }

    nonisolated static func displayName(
        name: String, rootPath: String, source: ProjectLaunchSource
    ) -> String? {
        guard let tomlData = source.fileContents(atPath: rootPath + "/dashboard.toml"),
              let toml = String(data: tomlData, encoding: .utf8)
        else { return nil }
        let display = parseProjectDisplayName(toml: toml)
        return display
    }

    nonisolated static func buildTargets(
        name: String, rootPath: String, source: ProjectLaunchSource, lastRuns: [String: Date]
    ) -> [ProjectTarget] {
        var targets: [ProjectTarget] = []
        let idPrefix = "\(name)#"
        if source.fileExists(atPath: rootPath + "/scripts/dashboard.py") {
            targets.append(ProjectTarget(
                id: idPrefix + "board", projectRoot: rootPath, projectName: name,
                name: "board", label: "Board", kind: .board,
                command: ["python3", "scripts/dashboard.py", "up"], urlKind: .board))
        }
        if let tomlData = source.fileContents(atPath: rootPath + "/dashboard.toml"),
           let toml = String(data: tomlData, encoding: .utf8) {
            for task in parseDashboardTasks(toml: toml) {
                targets.append(ProjectTarget(
                    id: idPrefix + task.name, projectRoot: rootPath, projectName: name,
                    name: task.name, label: task.label, kind: .task,
                    command: task.command, urlKind: .none, busy: task.busy))
            }
        }
        if let packageData = source.fileContents(atPath: rootPath + "/package.json") {
            for script in Self.parsePackageScripts(json: packageData) {
                let command = script == "start" ? ["npm", "start"] : ["npm", "run", script]
                targets.append(ProjectTarget(
                    id: idPrefix + script, projectRoot: rootPath, projectName: name,
                    name: script, label: "npm \(script == "start" ? "start" : "run \(script)")",
                    kind: .devServer, command: command, urlKind: .none))
            }
        }
        for script in Self.entryScripts
            where source.fileExists(atPath: rootPath + "/scripts/\(script)") {
            targets.append(ProjectTarget(
                id: idPrefix + script, projectRoot: rootPath, projectName: name,
                name: script, label: script, kind: .build,
                command: ["scripts/\(script)"], urlKind: .none))
        }
        for index in targets.indices {
            targets[index].lastRunAt = lastRuns[targets[index].id]
        }
        return targets
    }

    nonisolated static func sortTargets(_ targets: [ProjectTarget]) -> [ProjectTarget] {
        targets.sorted {
            switch ($0.lastRunAt, $1.lastRunAt) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case let (.some(a), .some(b)): return a == b ? false : a > b
            }
        }
    }

    // MARK: Run

    /// Runs the target without blocking: boards reuse the serving URL when
    /// there is one, anything else spawns detached and records pid +
    /// `lastRunAt` immediately. Re-entrant taps return `.failed`.
    public func run(_ target: ProjectTarget) async -> ProjectLaunchOutcome {
        guard !busyIDs.contains(target.id) else { return .failed }
        busyIDs.insert(target.id)
        defer { busyIDs.remove(target.id) }
        return await runUnchecked(target)
    }

    /// Holds the busy guard across the stop and the run, so a second tap
    /// mid-restart returns `.failed` instead of stacking servers.
    public func restart(_ target: ProjectTarget) async -> ProjectLaunchOutcome {
        guard !busyIDs.contains(target.id) else { return .failed }
        busyIDs.insert(target.id)
        defer { busyIDs.remove(target.id) }
        await stop(target)
        return await runUnchecked(target)
    }

    private func runUnchecked(_ target: ProjectTarget) async -> ProjectLaunchOutcome {
        if target.kind == .board {
            if let url = await source.runningBoardURL(rootPath: target.projectRoot) {
                recordRun(target)
                return .alreadyRunning(url)
            }
            switch await source.boardUp(rootPath: target.projectRoot) {
            case .started(let url):
                recordRun(target)
                return .started(url)
            case .alreadyRunning(let url):
                recordRun(target)
                return .alreadyRunning(url)
            case .failed:
                return .failed
            }
        }
        let logPath = source.logDirectory()
            .appendingPathComponent(
                "\(Self.sanitizeLogComponent(target.projectName))-\(Self.sanitizeLogComponent(target.name)).log"
            ).path
        guard let pid = source.spawn(
            command: target.command, workingDirectory: target.projectRoot, logPath: logPath)
        else { return .failed }
        pids[target.id] = pid
        recordRun(target)
        return .started(nil)
    }

    /// Boards resolve through launch.json plus a port probe; processes read
    /// as running only while the source still holds their child. A dead
    /// pid is dropped, so it reads as stopped from here on.
    public func status(of target: ProjectTarget) async -> ProjectTargetStatus {
        if target.kind == .board {
            return await source.runningBoardURL(rootPath: target.projectRoot) != nil
                ? .running : .stopped
        }
        guard let pid = pids[target.id] else { return .stopped }
        guard source.isPidAlive(pid) else {
            pids.removeValue(forKey: target.id)
            return .stopped
        }
        return .running
    }

    /// Boards go down through `dashboard.py down`; processes get SIGTERM and
    /// then SIGKILL past the grace interval when they linger.
    public func stop(_ target: ProjectTarget) async {
        if target.kind == .board {
            await source.boardDown(rootPath: target.projectRoot)
            pids.removeValue(forKey: target.id)
            return
        }
        guard let pid = pids[target.id] else { return }
        source.terminate(pid)
        if stopGraceInterval > 0 {
            try? await Task.sleep(nanoseconds: UInt64(stopGraceInterval * 1_000_000_000))
        }
        if source.isPidAlive(pid) {
            source.kill(pid)
        }
        pids.removeValue(forKey: target.id)
    }

    // MARK: - Last-run persistence

    func recordRun(_ target: ProjectTarget) {
        let at = source.now()
        lastRuns[target.id] = at
        Self.saveLastRuns(lastRuns, to: defaults)
        for projectIndex in projects.indices {
            if let targetIndex = projects[projectIndex].targets.firstIndex(where: { $0.id == target.id }) {
                let project = projects[projectIndex]
                var targets = project.targets
                targets[targetIndex].lastRunAt = at
                projects[projectIndex] = DiscoveredProject(
                    name: project.name, rootPath: project.rootPath,
                    displayName: project.displayName,
                    targets: Self.sortTargets(targets))
                break
            }
        }
    }

    /// A failed decode is bytes we do not understand, never bytes we may
    /// replace: it reads as empty and stays on disk until the next run
    /// overwrites it.
    static func loadLastRuns(from defaults: UserDefaults) -> [String: Date] {
        guard let data = defaults.data(forKey: lastRunDefaultsKey),
              let store = try? JSONDecoder().decode(LastRunStore.self, from: data)
        else { return [:] }
        return store.runs
    }

    static func saveLastRuns(_ runs: [String: Date], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(LastRunStore.self(from: runs)) else { return }
        defaults.set(data, forKey: lastRunDefaultsKey)
    }

    // MARK: - Minimal parsing (no new dependencies)

    nonisolated struct ParsedTask: Sendable, Equatable {
        let name: String
        let label: String
        let command: [String]
        let busy: String?
    }

    /// Reads `[[task]]` blocks out of `dashboard.toml`, skipping the push
    /// task — the one command that leaves the machine. Tolerates missing
    /// labels (falls back to the name) and malformed blocks (skipped).
    nonisolated static func parseDashboardTasks(toml: String) -> [ParsedTask] {
        var tasks: [ParsedTask] = []
        for block in toml.components(separatedBy: "[[task]]").dropFirst() {
            guard let name = field("name", in: block),
                  let command = arrayField("command", in: block),
                  !command.isEmpty
            else { continue }
            if command.contains("git") && command.contains("push") { continue }
            tasks.append(ParsedTask(
                name: name, label: field("label", in: block) ?? name,
                command: command, busy: field("busy", in: block)))
        }
        return tasks
    }

    /// The `[project] name` out of `dashboard.toml`, when the checkout sets one.
    nonisolated static func parseProjectDisplayName(toml: String) -> String? {
        var inProject = false
        for line in toml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inProject = trimmed == "[project]"
                continue
            }
            guard inProject else { continue }
            if let value = valueAfterKey("name", in: trimmed) {
                return value
            }
        }
        return nil
    }

    /// The `dev`/`start` scripts out of `package.json`, dev first. Anything
    /// else in the file reads as no dev server, never as a throw.
    nonisolated static func parsePackageScripts(json: Data) -> [String] {
        guard let doc = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let scripts = doc["scripts"] as? [String: Any]
        else { return [] }
        return ["dev", "start"].filter { scripts[$0] is String }
    }

    /// Log filenames come from checkout and target names, so anything
    /// outside `[A-Za-z0-9._-]` becomes a dash before the path is built.
    nonisolated static func sanitizeLogComponent(_ raw: String) -> String {
        String(raw.map { char in
            switch char {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-": char
            default: "-"
            }
        })
    }

    nonisolated private static func field(_ key: String, in block: String) -> String? {
        for line in block.components(separatedBy: .newlines) {
            if let value = valueAfterKey(key, in: line.trimmingCharacters(in: .whitespaces)) {
                return value
            }
        }
        return nil
    }

    /// The value after `key =`, with a trailing `#` comment cut and quotes
    /// stripped. Nil when the line is not a `key = "value"` line.
    nonisolated private static func valueAfterKey(_ key: String, in trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix(key) else { return nil }
        let rest = trimmedLine.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("=") else { return nil }
        let value = stripComment(String(rest.dropFirst())).trimmingCharacters(in: .whitespaces)
        return unquote(value)
    }

    nonisolated private static func arrayField(_ key: String, in block: String) -> [String]? {
        let lines = block.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key) else { index += 1; continue }
            let rest = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { index += 1; continue }
            // The array may wrap over lines, so keep joining comment-free
            // lines until the brackets balance.
            var joined = stripComment(String(rest.dropFirst()))
            while openBrackets(joined) > closeBrackets(joined), index + 1 < lines.count {
                index += 1
                joined += "\n" + stripComment(lines[index])
            }
            let value = joined.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("["), value.hasSuffix("]") else { return nil }
            let inner = value.dropFirst().dropLast()
            return splitArrayItems(String(inner)).compactMap {
                unquote($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return nil
    }

    /// Raw bracket counts; quotes holding brackets are rare in commands and
    /// not worth a full parser here.
    nonisolated private static func openBrackets(_ text: String) -> Int {
        text.filter { $0 == "[" }.count
    }

    nonisolated private static func closeBrackets(_ text: String) -> Int {
        text.filter { $0 == "]" }.count
    }

    /// Cuts a trailing `#` comment, leaving `#` inside quotes alone.
    nonisolated private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var result = line
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if let open = quote {
                if open == "\"" && char == "\\" {
                    index = line.index(after: index)
                    if index < line.endIndex { index = line.index(after: index) }
                    continue
                }
                if char == open { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == "#" {
                result = String(line[..<index])
                break
            }
            index = line.index(after: index)
        }
        return result
    }

    /// Splits on commas outside quotes, so `["a,b", "c"]` stays two items.
    nonisolated private static func splitArrayItems(_ inner: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        var index = inner.startIndex
        while index < inner.endIndex {
            let char = inner[index]
            if let open = quote {
                current.append(char)
                if open == "\"" && char == "\\", inner.index(after: index) < inner.endIndex {
                    index = inner.index(after: index)
                    current.append(inner[index])
                } else if char == open {
                    quote = nil
                }
            } else if char == "\"" || char == "'" {
                quote = char
                current.append(char)
            } else if char == "," {
                items.append(current)
                current = ""
            } else {
                current.append(char)
            }
            index = inner.index(after: index)
        }
        items.append(current)
        return items
    }

    nonisolated private static func unquote(_ raw: String) -> String? {
        guard raw.count >= 2,
              (raw.hasPrefix("\"") && raw.hasSuffix("\"")) || (raw.hasPrefix("'") && raw.hasSuffix("'"))
        else { return nil }
        return String(raw.dropFirst().dropLast())
    }
}

/// The persisted `lastRunAt` map: target id to last run. `CodingKeys` are
/// pinned to the on-disk names — renaming a property must not rename the
/// stored key.
struct LastRunStore: Codable {
    var runs: [String: Date]

    enum CodingKeys: String, CodingKey {
        case runs = "runs"
    }

    init(from runs: [String: Date]) {
        self.runs = runs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runs = (try? container.decode([String: Date].self, forKey: .runs)) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runs, forKey: .runs)
    }
}
