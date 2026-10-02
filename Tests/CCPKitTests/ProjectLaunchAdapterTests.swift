// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import Foundation
import XCTest

@MainActor
final class ProjectLaunchAdapterTests: XCTestCase {
    // MARK: - Fixtures

    /// Filesystem shaped like the real sibling checkouts: a control-center-pro
    /// with a board, two non-push tasks and `scripts/app.sh`; a psymail-mini
    /// with a board, three non-push tasks and `scripts/ios.sh`; a node project
    /// with dev/start scripts. Twelve extra stale checkouts push the total
    /// past the ten-project cap.
    func fixtureSource() -> FakeProjectLaunchSource {
        let source = FakeProjectLaunchSource()
        let ccpTOML = """
            [project]

            [[task]]
            name = "verify"
            command = ["scripts/verify.sh"]
            label = "run"
            busy = "running…"
            where = "gate"

            [[task]]
            name = "run-mac"
            command = ["scripts/app.sh", "--launch", "--show-panel"]
            label = "run mac"
            busy = "building…"
            where = "header"

            [[task]]
            name = "push"
            command = ["git", "push"]
            label = "push"
            busy = "pushing…"
            where = "lane:staging"
            """
        let psymailTOML = """
            [project]
            name = "psymail mini"

            [[task]]
            name = "mac"
            command = ["scripts/mac.sh", "install"]
            label = "run mac"
            busy = "run mac…"
            where = "header"

            [[task]]
            name = "ios"
            command = ["scripts/ios.sh", "run"]
            label = "run ios"
            busy = "run ios…"
            where = "header"

            [[task]]
            name = "verify"
            command = ["scripts/verify.sh"]
            label = "run"
            busy = "running…"
            where = "gate"

            [[task]]
            name = "push"
            command = ["git", "push"]
            label = "push"
            busy = "pushing…"
            where = "lane:staging"
            """
        let nodePackage = """
            {"name":"demo","scripts":{"dev":"vite","start":"node server.js","test":"vitest"}}
            """
        source.addProject(name: "control-center-pro", mtime: 300,
                          files: ["scripts/dashboard.py": "", "dashboard.toml": ccpTOML,
                                  "scripts/app.sh": ""])
        source.addProject(name: "psymail-mini", mtime: 200,
                          files: ["scripts/dashboard.py": "", "dashboard.toml": psymailTOML,
                                  "scripts/ios.sh": "", "scripts/mac.sh": ""])
        source.addProject(name: "node-demo", mtime: 100, files: ["package.json": nodePackage])
        for index in 0..<12 {
            source.addProject(name: "stale-\(index)", mtime: Double(10 - index), files: [:])
        }
        return source
    }

    func ephemeralDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ccp.projectLaunch.tests.\(UUID().uuidString)") ?? .standard
    }

    func target(in adapter: ProjectLaunchAdapter, project: String, name: String) -> ProjectTarget {
        guard let found = adapter.projects.first(where: { $0.name == project })?
            .targets.first(where: { $0.name == name })
        else { preconditionFailure("missing target \(project)#\(name)") }
        return found
    }

    // MARK: - Discovery

    func testDiscoveryCapsAtTenProjectsInMtimeOrder() async {
        let source = fixtureSource()
        let adapter = ProjectLaunchAdapter(source: source, defaults: ephemeralDefaults())
        await adapter.discover()

        XCTAssertEqual(adapter.projects.count, 10)
        let names = adapter.projects.map(\.name)
        XCTAssertEqual(Array(names.prefix(3)), ["control-center-pro", "psymail-mini", "node-demo"])
        let expected = source.devEntries().sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(10).map(\.name)
        XCTAssertEqual(names, expected)
    }

    func testDiscoveryFindsControlCenterProTargets() async {
        let adapter = ProjectLaunchAdapter(source: fixtureSource(), defaults: ephemeralDefaults())
        await adapter.discover()

        let project = adapter.projects.first(where: { $0.name == "control-center-pro" })
        XCTAssertNotNil(project)
        let kinds = (project?.targets ?? []).map { ($0.name, $0.kind) }
        XCTAssertTrue(kinds.contains { $0 == ("board", .board) })
        XCTAssertTrue(kinds.contains { $0 == ("verify", .task) })
        XCTAssertTrue(kinds.contains { $0 == ("run-mac", .task) })
        XCTAssertTrue(kinds.contains { $0 == ("app.sh", .build) })
        XCTAssertFalse(kinds.contains { $0.0 == "push" }, "the push task must never become a target")
        XCTAssertEqual(project?.targets.first(where: { $0.name == "board" })?.urlKind, .board)
        XCTAssertEqual(
            project?.targets.first(where: { $0.name == "board" })?.command,
            ["python3", "scripts/dashboard.py", "up"])
    }

    func testDiscoveryFindsPsymailMiniTargets() async {
        let adapter = ProjectLaunchAdapter(source: fixtureSource(), defaults: ephemeralDefaults())
        await adapter.discover()

        let project = adapter.projects.first(where: { $0.name == "psymail-mini" })
        let names = (project?.targets ?? []).map(\.name)
        XCTAssertTrue(names.contains("board"))
        XCTAssertTrue(names.contains("mac"))
        XCTAssertTrue(names.contains("ios"))
        XCTAssertTrue(names.contains("verify"))
        XCTAssertTrue(names.contains("ios.sh"))
        XCTAssertTrue(names.contains("mac.sh"))
        XCTAssertFalse(names.contains("push"))
    }

    func testDiscoveryFindsPackageJsonDevServers() async {
        let adapter = ProjectLaunchAdapter(source: fixtureSource(), defaults: ephemeralDefaults())
        await adapter.discover()

        let project = adapter.projects.first(where: { $0.name == "node-demo" })
        let dev = project?.targets.first(where: { $0.name == "dev" })
        let start = project?.targets.first(where: { $0.name == "start" })
        XCTAssertEqual(dev?.kind, .devServer)
        XCTAssertEqual(dev?.command, ["npm", "run", "dev"])
        XCTAssertEqual(start?.command, ["npm", "start"])
        XCTAssertNil(project?.targets.first(where: { $0.name == "test" }),
                     "only dev/start scripts become targets")
    }

    func testTomlParsingSkipsPushAndToleratesMalformedBlocks() {
        let tasks = ProjectLaunchAdapter.parseDashboardTasks(toml: """
            [[task]]
            name = "ok"
            command = ["scripts/verify.sh"]

            [[task]]
            name = "push"
            command = ["git", "push"]

            [[task]]
            name = "broken"
            """)
        XCTAssertEqual(tasks.map(\.name), ["ok"])
        XCTAssertEqual(tasks.first?.label, "ok", "a missing label falls back to the name")
    }

    func testTomlParsingIsQuoteAwareAndStripsComments() {
        let tasks = ProjectLaunchAdapter.parseDashboardTasks(toml: """
            [[task]]
            name = "quoted" # trailing comment
            command = ["sh", "-c", "echo a,b,c"] # another comment
            label = "quoted label" # comment
            busy = "working…" # comment

            [[task]]
            name = "multi"
            command = [
                "scripts/run.sh",
                "--flag",
            ]
            """)
        XCTAssertEqual(tasks.map(\.name), ["quoted", "multi"])
        XCTAssertEqual(tasks.first?.command, ["sh", "-c", "echo a,b,c"],
                       "commas inside quotes never split")
        XCTAssertEqual(tasks.first?.label, "quoted label")
        XCTAssertEqual(tasks.first?.busy, "working…")
        XCTAssertEqual(tasks.last?.command, ["scripts/run.sh", "--flag"],
                       "a command wrapped over lines still parses")
        XCTAssertNil(tasks.last?.busy)
    }

    func testTomlParsingSkipsPushInAnyPosition() {
        let tasks = ProjectLaunchAdapter.parseDashboardTasks(toml: """
            [[task]]
            name = "force-push"
            command = ["git", "-C", "subdir", "push", "origin"]

            [[task]]
            name = "status"
            command = ["sh", "-c", "git status"]
            """)
        XCTAssertEqual(tasks.map(\.name), ["status"],
                       "git and push anywhere in the command is the push task; substrings don't count")
    }

    func testDiscoveryReadsProjectDisplayNameAndBusy() async {
        let adapter = ProjectLaunchAdapter(source: fixtureSource(), defaults: ephemeralDefaults())
        await adapter.discover()

        XCTAssertEqual(adapter.projects.first(where: { $0.name == "psymail-mini" })?.displayName,
                       "psymail mini")
        let ccp = adapter.projects.first(where: { $0.name == "control-center-pro" })
        XCTAssertNil(ccp?.displayName, "a [project] section without a name leaves no display name")
        XCTAssertEqual(ccp?.targets.first(where: { $0.name == "verify" })?.busy, "running…")
    }

    // MARK: - Run

    func testRunSpawnsWithoutBlockingAndRecordsPidAndTimestamp() async {
        let source = fixtureSource()
        source.fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let adapter = ProjectLaunchAdapter(source: source, defaults: ephemeralDefaults())
        await adapter.discover()
        let verify = target(in: adapter, project: "control-center-pro", name: "verify")

        let outcome = await adapter.run(verify)

        XCTAssertEqual(outcome, .started(nil))
        XCTAssertNotNil(adapter.pid(for: verify))
        XCTAssertEqual(adapter.lastRunAt(for: verify), source.fixedNow)
        XCTAssertEqual(source.spawned.map(\.command), [["scripts/verify.sh"]])
        XCTAssertEqual(source.spawned.first?.workingDirectory, "/dev/control-center-pro")
        XCTAssertFalse(adapter.isBusy(verify), "the busy flag clears after launch")
    }

    func testRunPersistsLastRunAcrossAdapters() async {
        let defaults = ephemeralDefaults()
        let source = fixtureSource()
        let first = ProjectLaunchAdapter(source: source, defaults: defaults)
        await first.discover()
        _ = await first.run(target(in: first, project: "control-center-pro", name: "verify"))

        let second = ProjectLaunchAdapter(source: fixtureSource(), defaults: defaults)
        await second.discover()

        XCTAssertNotNil(second.projects.first(where: { $0.name == "control-center-pro" })?
            .targets.first(where: { $0.name == "verify" })?.lastRunAt,
            "lastRunAt survives a fresh adapter on the same defaults")
    }

    func testFailedSpawnReadsAsFailed() async {
        let source = fixtureSource()
        source.spawnResult = nil
        let adapter = ProjectLaunchAdapter(source: source, defaults: ephemeralDefaults())
        await adapter.discover()

        let outcome = await adapter.run(target(in: adapter, project: "control-center-pro", name: "verify"))

        XCTAssertEqual(outcome, .failed)
    }

    // MARK: - Board URL reuse

    func testRunningBoardTapReusesURLWithoutSpawning() async {
        let source = fixtureSource()
        let boardURL = URL(string: "http://localhost:7393/")!
        source.boardRunningURL = boardURL
        let adapter = ProjectLaunchAdapter(source: source, defaults: ephemeralDefaults())
        await adapter.discover()

        let outcome = await adapter.run(target(in: adapter, project: "control-center-pro", name: "board"))

        XCTAssertEqual(outcome, .alreadyRunning(boardURL))
        XCTAssertTrue(source.opened.isEmpty, "opening moved to the view — the adapter only reports the URL")
        XCTAssertEqual(source.upCount, 0, "a running board must be opened, not relaunched")
        XCTAssertNotNil(adapter.lastRunAt(for: target(in: adapter, project: "control-center-pro", name: "board")))
    }

    func testStoppedBoardTapBringsUpAndOpens() async {
        let source = fixtureSource()
        let boardURL = URL(string: "http://localhost:7391/")!
        source.boardRunningURL = nil
        source.upResult = .started(boardURL)
        let adapter = ProjectLaunchAdapter(source: source, defaults: ephemeralDefaults())
        await adapter.discover()

        let outcome = await adapter.run(target(in: adapter, project: "control-center-pro", name: "board"))

        XCTAssertEqual(outcome, .started(boardURL))
        XCTAssertEqual(source.upCount, 1)
        XCTAssertTrue(source.opened.isEmpty, "opening moved to the view — the adapter only reports the URL")
    }

    // MARK: - Status / stop / restart

    func testStatusReadsLivePidAsRunningAndDropsDeadPid() async {
        let source = fixtureSource()
        let adapter = ProjectLaunchAdapter(source: source, defaults: ephemeralDefaults())
        await adapter.discover()
        let verify = target(in: adapter, project: "control-center-pro", name: "verify")
        _ = await adapter.run(verify)
        let pid = adapter.pid(for: verify)!

        source.alivePids = [pid]
        let running = await adapter.status(of: verify)
        XCTAssertEqual(running, .running)

        source.alivePids = []
        let stopped = await adapter.status(of: verify)
        XCTAssertEqual(stopped, .stopped)
        XCTAssertNil(adapter.pid(for: verify), "a dead pid is dropped and reads stopped after")
    }

    func testStatusWithNoPidIsStopped() async {
        let adapter = ProjectLaunchAdapter(source: fixtureSource(), defaults: ephemeralDefaults())
        await adapter.discover()
        let status = await adapter.status(
            of: target(in: adapter, project: "control-center-pro", name: "verify"))
        XCTAssertEqual(status, .stopped)
    }

    func testBoardStatusFollowsRunningURL() async {
        let source = fixtureSource()
        let adapter = ProjectLaunchAdapter(source: source, defaults: ephemeralDefaults())
        await adapter.discover()
        let board = target(in: adapter, project: "control-center-pro", name: "board")

        source.boardRunningURL = URL(string: "http://localhost:7393/")!
        let running = await adapter.status(of: board)
        XCTAssertEqual(running, .running)
        source.boardRunningURL = nil
        let stopped = await adapter.status(of: board)
        XCTAssertEqual(stopped, .stopped)
    }

    func testStopTerminatesAndKillsLingeringProcess() async {
        let source = fixtureSource()
        let adapter = ProjectLaunchAdapter(
            source: source, defaults: ephemeralDefaults(), stopGraceInterval: 0)
        await adapter.discover()
        let verify = target(in: adapter, project: "control-center-pro", name: "verify")
        _ = await adapter.run(verify)
        let pid = adapter.pid(for: verify)!

        await adapter.stop(verify)

        XCTAssertEqual(source.terminated, [pid])
        XCTAssertEqual(source.killed, [pid], "a pid alive past grace gets SIGKILL")
        XCTAssertNil(adapter.pid(for: verify))
        let stopped = await adapter.status(of: verify)
        XCTAssertEqual(stopped, .stopped)
    }

    func testStopSkipsKillWhenTerminateWorked() async {
        let source = fixtureSource()
        source.diesOnTerminate = true
        let adapter = ProjectLaunchAdapter(
            source: source, defaults: ephemeralDefaults(), stopGraceInterval: 0)
        await adapter.discover()
        let verify = target(in: adapter, project: "control-center-pro", name: "verify")
        _ = await adapter.run(verify)

        await adapter.stop(verify)

        XCTAssertEqual(source.terminated.count, 1)
        XCTAssertTrue(source.killed.isEmpty, "a pid that died on SIGTERM needs no SIGKILL")
    }

    func testBoardStopRunsDown() async {
        let source = fixtureSource()
        let adapter = ProjectLaunchAdapter(source: source, defaults: ephemeralDefaults())
        await adapter.discover()

        await adapter.stop(target(in: adapter, project: "control-center-pro", name: "board"))

        XCTAssertEqual(source.downRoots, ["/dev/control-center-pro"])
    }

    func testRestartRespawns() async {
        let source = fixtureSource()
        let adapter = ProjectLaunchAdapter(
            source: source, defaults: ephemeralDefaults(), stopGraceInterval: 0)
        await adapter.discover()
        let verify = target(in: adapter, project: "control-center-pro", name: "verify")
        _ = await adapter.run(verify)
        let firstPid = adapter.pid(for: verify)!

        let outcome = await adapter.restart(verify)

        XCTAssertEqual(outcome, .started(nil))
        XCTAssertEqual(source.spawned.count, 2, "restart stops then spawns again")
        XCTAssertNotEqual(adapter.pid(for: verify), firstPid)
    }

    func testRestartHoldsBusyAcrossStopAndRun() async {
        let source = fixtureSource()
        let adapter = ProjectLaunchAdapter(
            source: source, defaults: ephemeralDefaults(), stopGraceInterval: 0.2)
        await adapter.discover()
        let verify = target(in: adapter, project: "control-center-pro", name: "verify")
        _ = await adapter.run(verify)

        let first = Task { await adapter.restart(verify) }
        while !adapter.busyIDs.contains(verify.id) { await Task.yield() }
        let second = await adapter.restart(verify)

        XCTAssertEqual(second, .failed, "a re-entrant restart returns .failed per the busy contract")
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .started(nil))
        XCTAssertEqual(source.spawned.count, 2, "only the first restart spawns")
    }

    func testRunSanitizesLogPath() async {
        let source = fixtureSource()
        source.addProject(name: "weird name!", mtime: 400, files: ["scripts/app.sh": ""])
        let adapter = ProjectLaunchAdapter(source: source, defaults: ephemeralDefaults())
        await adapter.discover()

        _ = await adapter.run(target(in: adapter, project: "weird name!", name: "app.sh"))

        XCTAssertEqual(
            source.spawned.first?.logPath,
            "/tmp/ccp-project-launch-tests/logs/weird-name--app.sh.log")
    }

    func testLogComponentSanitization() {
        XCTAssertEqual(ProjectLaunchAdapter.sanitizeLogComponent("my proj@v2/x"), "my-proj-v2-x")
        XCTAssertEqual(ProjectLaunchAdapter.sanitizeLogComponent("a.b_c-d9"), "a.b_c-d9")
    }

    func testLiveSourceReapsExitedProcess() async {
        let source = LiveProjectLaunchSource()
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccp-reap-\(UUID().uuidString).log").path
        guard let pid = source.spawn(command: ["sleep", "0.3"], workingDirectory: "/tmp", logPath: log)
        else {
            XCTFail("spawn of sleep should succeed")
            return
        }
        XCTAssertTrue(source.isPidAlive(pid), "a retained child reads as running")
        var budget = 200
        while source.isPidAlive(pid), budget > 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            budget -= 1
        }
        XCTAssertFalse(source.isPidAlive(pid), "an exited child is reaped and reads as stopped")
        XCTAssertFalse(source.isPidAlive(.max), "a pid never spawned reads as stopped")
        try? FileManager.default.removeItem(atPath: log)
    }

    // MARK: - Sorting

    func testSortingPutsMostRecentlyRunFirst() async {
        let source = fixtureSource()
        let adapter = ProjectLaunchAdapter(source: source, defaults: ephemeralDefaults())
        await adapter.discover()
        let ccp = adapter.projects.first(where: { $0.name == "control-center-pro" })!
        XCTAssertEqual(ccp.targets.first?.name, "board", "discovery order leads before anything runs")

        source.fixedNow = Date(timeIntervalSince1970: 1_700_000_100)
        _ = await adapter.run(target(in: adapter, project: "control-center-pro", name: "verify"))
        source.fixedNow = Date(timeIntervalSince1970: 1_700_000_200)
        _ = await adapter.run(target(in: adapter, project: "control-center-pro", name: "app.sh"))

        let names = adapter.projects.first(where: { $0.name == "control-center-pro" })!.targets.map(\.name)
        XCTAssertEqual(Array(names.prefix(2)), ["app.sh", "verify"])
        XCTAssertNil(adapter.projects.first(where: { $0.name == "control-center-pro" })!
            .targets.last?.lastRunAt, "never-run targets sort last")
    }
}

// MARK: - Fake

/// In-memory `~/dev`, fake pids, scripted board answers. Spawns instantly and
/// never touches the network or the process table.
final class FakeProjectLaunchSource: ProjectLaunchSource, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(name: String, mtime: Date)] = []
    private var files: [String: Data] = [:]

    private var _spawned: [(command: [String], workingDirectory: String, logPath: String)] = []
    private var _nextPid: Int32 = 1000
    var spawnResult: Int32? = -1 // -1 means "mint the next pid"; nil means failure
    var alivePids: Set<Int32> = []
    var diesOnTerminate = false
    private var _terminated: [Int32] = []
    private var _killed: [Int32] = []

    var boardRunningURL: URL?
    var upResult: HarnessDashboardOutcome = .failed
    private var _upCount = 0
    private var _downRoots: [String] = []
    private var _opened: [URL] = []

    var fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    var spawned: [(command: [String], workingDirectory: String, logPath: String)] {
        lock.withLock { _spawned }
    }
    var terminated: [Int32] { lock.withLock { _terminated } }
    var killed: [Int32] { lock.withLock { _killed } }
    var upCount: Int { lock.withLock { _upCount } }
    var downRoots: [String] { lock.withLock { _downRoots } }
    var opened: [URL] { lock.withLock { _opened } }

    func addProject(name: String, mtime: TimeInterval, files: [String: String]) {
        lock.withLock {
            entries.append((name, Date(timeIntervalSince1970: mtime)))
            for (relative, contents) in files {
                self.files["/dev/\(name)/\(relative)"] = Data(contents.utf8)
            }
        }
    }

    func devEntries() -> [ProjectDevEntry] {
        lock.withLock {
            entries.map { ProjectDevEntry(name: $0.name, rootPath: "/dev/\($0.name)", modifiedAt: $0.mtime) }
        }
    }

    func fileExists(atPath path: String) -> Bool {
        lock.withLock { files[path] != nil }
    }

    func fileContents(atPath path: String) -> Data? {
        lock.withLock { files[path] }
    }

    func spawn(command: [String], workingDirectory: String, logPath: String) -> Int32? {
        lock.withLock {
            _spawned.append((command, workingDirectory, logPath))
            guard let result = spawnResult else { return nil }
            if result == -1 {
                _nextPid += 1
                alivePids.insert(_nextPid)
                return _nextPid
            }
            return result
        }
    }

    func isPidAlive(_ pid: Int32) -> Bool {
        lock.withLock { alivePids.contains(pid) }
    }

    func terminate(_ pid: Int32) {
        lock.withLock {
            _terminated.append(pid)
            if diesOnTerminate { alivePids.remove(pid) }
        }
    }

    func kill(_ pid: Int32) {
        lock.withLock {
            _killed.append(pid)
            alivePids.remove(pid)
        }
    }

    func runningBoardURL(rootPath: String) async -> URL? {
        lock.withLock { boardRunningURL }
    }

    func boardUp(rootPath: String) async -> HarnessDashboardOutcome {
        lock.withLock { _upCount += 1 }
        return lock.withLock { upResult }
    }

    func boardDown(rootPath: String) async {
        lock.withLock { _downRoots.append(rootPath) }
    }

    func open(_ url: URL) async {
        lock.withLock { _opened.append(url) }
    }

    func logDirectory() -> URL {
        URL(fileURLWithPath: "/tmp/ccp-project-launch-tests/logs")
    }

    func now() -> Date {
        lock.withLock { fixedNow }
    }
}
