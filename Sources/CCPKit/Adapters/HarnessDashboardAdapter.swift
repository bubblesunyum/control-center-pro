// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import Foundation
import Observation

/// One harness board the Tools strip can bring up with `dashboard up`.
///
/// Titles stay short on purpose: the strip's cell is 60pt wide, so the full
/// checkout name (`control-center-pro`, `fusebox-migration`) would truncate to
/// noise. The checkout id behind each title lives on `help` and the
/// accessibility label instead.
public struct HarnessDashboard: Sendable, Identifiable, Equatable {
    /// The harnesses, in the order their buttons draw.
    public static let dashboards: [HarnessDashboard] = [
        HarnessDashboard(id: "psymail-mini", title: "Psymail", rootPath: "/Users/bubbles/dev/psymail-mini"),
        HarnessDashboard(id: "control-center-pro", title: "CCP", rootPath: "/Users/bubbles/dev/control-center-pro"),
        HarnessDashboard(id: "bb-kit", title: "bb-kit", rootPath: "/Users/bubbles/dev/bb-kit"),
        HarnessDashboard(id: "fusebox-migration", title: "Fusebox", rootPath: "/Users/bubbles/dev/fusebox-migration"),
        HarnessDashboard(id: "harness-starter", title: "Starter", rootPath: "/Users/bubbles/dev/harness-starter"),
        HarnessDashboard(id: "folia", title: "Folia", rootPath: "/Users/bubbles/dev/folia"),
        HarnessDashboard(id: "gooey", title: "Gooey", rootPath: "/Users/bubbles/dev/gooey"),
    ]

    public let id: String
    public let title: String
    public let subtitle: String
    public let systemImage: String
    public let rootPath: String

    public var accessibilityLabel: String { "\(id) dashboard" }
    public var help: String { "Start the \(id) harness dashboard and open its board" }

    public init(id: String, title: String, subtitle: String = "Dashboard",
                systemImage: String = "square.grid.2x2", rootPath: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.rootPath = rootPath
    }
}

/// What a `dashboard up` tap came to.
public enum HarnessDashboardOutcome: Sendable, Equatable {
    /// A server was started; the board is at the URL.
    case started(URL)
    /// One was already serving; the board is at the URL.
    case alreadyRunning(URL)
    case failed

    public var url: URL? {
        switch self {
        case .started(let url), .alreadyRunning(let url): return url
        case .failed: return nil
        }
    }
}

// MARK: - Source

/// The seam a test stands a fake in for: spawning `dashboard.py up` and
/// opening the board are not things a test should trigger.
public protocol HarnessDashboardSource: AnyObject, Sendable {
    func runUp(rootPath: String) async -> HarnessDashboardOutcome
    func runningURL(rootPath: String) async -> URL?
    func open(_ url: URL)
}

/// The real one, talking to each checkout's `scripts/dashboard.py`.
public final class LiveHarnessDashboardSource: HarnessDashboardSource {
    public init() {}

    public func runUp(rootPath: String) async -> HarnessDashboardOutcome {
        let output = await Task.detached(priority: .userInitiated) {
            Self.upOutput(rootPath: rootPath)
        }.value
        guard let url = Self.url(fromUpOutput: output) else { return .failed }
        // psymail-mini's `up` returns before its child binds; the newer ones
        // wait server-side, so this is a no-op for them. Either way the board
        // only opens once something actually answers on the port.
        guard await Self.waitUntilServing(url: url) else { return .failed }
        return output.contains("already") ? .alreadyRunning(url) : .started(url)
    }

    /// The board URL when this checkout already has one serving, else nil.
    /// Read off `.claude/launch.json`, which `dashboard.py` rewrites on every
    /// bind — a stale entry pointing at nothing serving, or at a port another
    /// checkout has since taken, reads as not running, so those taps still
    /// fall through to `up`, whose own port-holder check routes around
    /// foreign boards.
    public func runningURL(rootPath: String) async -> URL? {
        guard let url = Self.launchURL(rootPath: rootPath),
              let port = url.port,
              Self.claimRoot(port: port) == rootPath
        else { return nil }
        guard await Self.isServing(url: url) else { return nil }
        return url
    }

    public func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Runs `dashboard up` in the checkout and returns its combined output.
    /// `up` detaches its server and exits, so this returns quickly either way;
    /// a missing checkout or interpreter surfaces as empty output, which parses
    /// to `.failed` downstream rather than throwing here.
    nonisolated static func upOutput(rootPath: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "scripts/dashboard.py", "up"]
        process.currentDirectoryURL = URL(fileURLWithPath: rootPath)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ""
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Reads the board URL out of `up` output. The newer harnesses print
    /// `harness dashboard → http://localhost:PORT/ (note)`; psymail-mini's
    /// older script prints `already serving on PORT` / `started on PORT`.
    nonisolated static func url(fromUpOutput output: String) -> URL? {
        if let match = output.range(of: #"http://localhost:\d+/?"#, options: .regularExpression) {
            return URL(string: String(output[match]))
        }
        if let match = output.range(of: #"(?:started|serving) on (\d+)"#, options: .regularExpression) {
            let digits = output[match].components(separatedBy: CharacterSet.decimalDigits.inverted)
                .filter { !$0.isEmpty }.last
            if let port = digits {
                return URL(string: "http://localhost:\(port)/")
            }
        }
        return nil
    }

    /// True once something answers at the URL. A just-spawned child needs a
    /// moment to bind, and opening the link before that is a blank tab.
    nonisolated static func waitUntilServing(url: URL, timeout: TimeInterval = 5) async -> Bool {
        let session = Self.probeSession()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                _ = try await session.data(from: url)
                return true
            } catch {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return false
    }

    /// One probe, not a wait: the pre-launch check must answer fast enough
    /// that a tap on a stopped board still feels like a tap.
    nonisolated static func isServing(url: URL) async -> Bool {
        do {
            _ = try await Self.probeSession().data(from: url)
            return true
        } catch {
            return false
        }
    }

    nonisolated static func probeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.5
        config.timeoutIntervalForResource = 0.5
        return URLSession(configuration: config)
    }

    /// Which checkout holds this port, per the claim file its server wrote on
    /// bind — nil when nothing claimed it. The prefix varies per checkout
    /// (each ledger has its own), so the suffix is what identifies a claim.
    /// Missing or unreadable reads as unclaimed, never as ours: the tap then
    /// falls through to `up` rather than opening a stranger's board. Claims
    /// whose pid is dead are skipped: a crash leaves the file behind, and a
    /// checkout that has since taken the port must not read as still ours.
    nonisolated static func claimRoot(port: Int) -> String? {
        let suffix = "-dashboard-\(port).json"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/tmp") else { return nil }
        for name in names where name.hasSuffix(suffix) {
            let path = "/tmp/\(name)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let root = doc["root"] as? String
            else { continue }
            if let pid = doc["pid"] as? Int, !Self.isPidAlive(pid) { continue }
            return root
        }
        return nil
    }

    nonisolated static func isPidAlive(_ pid: Int) -> Bool {
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /// The board URL `dashboard.py` last published for this checkout, if any.
    /// Tolerates a missing file, unreadable JSON, and the wrong shape — all
    /// read as "no board", never as a throw, since this runs on every tap.
    nonisolated static func launchURL(rootPath: String) -> URL? {
        let path = URL(fileURLWithPath: rootPath).appendingPathComponent(".claude/launch.json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return Self.launchURL(fromLaunchJSON: data)
    }

    nonisolated static func launchURL(fromLaunchJSON data: Data) -> URL? {
        guard let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let configs = doc["configurations"] as? [[String: Any]]
        else { return nil }
        for config in configs {
            guard (config["name"] as? String) == "harness-dashboard",
                  let urlString = config["url"] as? String,
                  let url = URL(string: urlString),
                  url.scheme == "http" || url.scheme == "https"
            else { continue }
            return url
        }
        return nil
    }
}

// MARK: - Adapter

/// The Tools strip's model for the harness dashboards.
///
/// A tap reuses the checkout's running board when it has one and only runs
/// `up` when nothing answers; the busy flag guards against a second tap
/// while the first is still bringing its server up.
@MainActor
@Observable
public final class HarnessDashboardAdapter {
    public private(set) var busyIDs: Set<String> = []

    @ObservationIgnored private let source: HarnessDashboardSource

    public convenience init() {
        self.init(source: LiveHarnessDashboardSource())
    }

    public init(source: HarnessDashboardSource) {
        self.source = source
    }

    public func isBusy(_ dashboard: HarnessDashboard) -> Bool {
        busyIDs.contains(dashboard.id)
    }

    /// Open the checkout's board, starting its server first when none is
    /// serving. Re-entrant taps on the same board return `.failed` rather
    /// than stacking servers; the button is disabled while busy so this is
    /// unreachable from the UI.
    public func launch(_ dashboard: HarnessDashboard) async -> HarnessDashboardOutcome {
        guard !busyIDs.contains(dashboard.id) else { return .failed }
        busyIDs.insert(dashboard.id)
        defer { busyIDs.remove(dashboard.id) }
        if let url = await source.runningURL(rootPath: dashboard.rootPath) {
            source.open(url)
            return .alreadyRunning(url)
        }
        let outcome = await source.runUp(rootPath: dashboard.rootPath)
        if let url = outcome.url {
            source.open(url)
        }
        return outcome
    }
}
