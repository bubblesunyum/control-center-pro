// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import Foundation
import XCTest

@MainActor
final class HarnessDashboardAdapterTests: XCTestCase {
    // MARK: - Catalogue

    func testDashboardsListsHarnessesInOrder() {
        let ids = HarnessDashboard.dashboards.map(\.id)
        XCTAssertEqual(ids, ["psymail-mini", "control-center-pro", "bb-kit", "fusebox-migration", "harness-starter", "folia", "gooey"])
    }

    func testDashboardsPointAtFixedSiblingCheckouts() {
        let roots = HarnessDashboard.dashboards.map(\.rootPath)
        XCTAssertEqual(roots, [
            "/Users/bubbles/dev/psymail-mini",
            "/Users/bubbles/dev/control-center-pro",
            "/Users/bubbles/dev/bb-kit",
            "/Users/bubbles/dev/fusebox-migration",
            "/Users/bubbles/dev/harness-starter",
            "/Users/bubbles/dev/folia",
            "/Users/bubbles/dev/gooey",
        ])
    }

    // MARK: - URL parsing

    func testParsesNewStyleAnnounceURL() {
        let url = LiveHarnessDashboardSource.url(fromUpOutput:
            "harness dashboard → http://localhost:7393/   (started)\nopen it in Claude Code's browser pane")
        XCTAssertEqual(url?.absoluteString, "http://localhost:7393/")
    }

    func testParsesAlreadyRunningAnnounceURL() {
        let url = LiveHarnessDashboardSource.url(fromUpOutput:
            "harness dashboard → http://localhost:7391/   (already running)")
        XCTAssertEqual(url?.absoluteString, "http://localhost:7391/")
    }

    func testParsesLegacyStartedOnPort() {
        XCTAssertEqual(
            LiveHarnessDashboardSource.url(fromUpOutput: "started on 7392")?.absoluteString,
            "http://localhost:7392/")
    }

    func testParsesLegacyAlreadyServingOnPort() {
        XCTAssertEqual(
            LiveHarnessDashboardSource.url(fromUpOutput: "already serving on 7394")?.absoluteString,
            "http://localhost:7394/")
    }

    func testUnrecognizedOutputParsesToNil() {
        XCTAssertNil(LiveHarnessDashboardSource.url(fromUpOutput: ""))
        XCTAssertNil(LiveHarnessDashboardSource.url(fromUpOutput: "! nothing came up on 7391 — see /tmp/ccp-dash.log"))
        XCTAssertNil(LiveHarnessDashboardSource.url(fromUpOutput: "no such command: up"))
    }

    // MARK: - Launch

    func testLaunchRunsUpInTheDashboardCheckout() async {
        let source = FakeDashboardSource(result: .started(URL(string: "http://localhost:7393/")!))
        let adapter = HarnessDashboardAdapter(source: source)
        let dashboard = HarnessDashboard.dashboards[0]

        let outcome = await adapter.launch(dashboard)

        XCTAssertEqual(source.runRoots, ["/Users/bubbles/dev/psymail-mini"])
        XCTAssertEqual(outcome, .started(URL(string: "http://localhost:7393/")!))
    }

    func testLaunchOpensTheBoardOnSuccess() async {
        let url = URL(string: "http://localhost:7393/")!
        let source = FakeDashboardSource(result: .started(url))
        let adapter = HarnessDashboardAdapter(source: source)

        _ = await adapter.launch(HarnessDashboard.dashboards[0])

        XCTAssertEqual(source.opened, [url])
    }

    func testLaunchOpensTheBoardWhenAlreadyRunning() async {
        let url = URL(string: "http://localhost:7391/")!
        let source = FakeDashboardSource(result: .alreadyRunning(url))
        let adapter = HarnessDashboardAdapter(source: source)

        let outcome = await adapter.launch(HarnessDashboard.dashboards[1])

        XCTAssertEqual(outcome, .alreadyRunning(url))
        XCTAssertEqual(source.opened, [url])
    }

    func testLaunchOpensNothingOnFailure() async {
        let source = FakeDashboardSource(result: .failed)
        let adapter = HarnessDashboardAdapter(source: source)

        let outcome = await adapter.launch(HarnessDashboard.dashboards[2])

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(source.opened.isEmpty)
    }

    func testBusyFlagClearsAfterLaunch() async {
        let source = FakeDashboardSource(result: .failed)
        let adapter = HarnessDashboardAdapter(source: source)
        let dashboard = HarnessDashboard.dashboards[3]

        XCTAssertFalse(adapter.isBusy(dashboard))
        _ = await adapter.launch(dashboard)
        XCTAssertFalse(adapter.isBusy(dashboard))
    }

    func testSecondTapWhileBusyDoesNotStackServers() async {
        let source = FakeDashboardSource(result: .failed)
        source.hold = true
        let adapter = HarnessDashboardAdapter(source: source)
        let dashboard = HarnessDashboard.dashboards[0]

        let first = Task { await adapter.launch(dashboard) }
        while source.runCount == 0 { await Task.yield() }
        XCTAssertTrue(adapter.isBusy(dashboard))

        let second = await adapter.launch(dashboard)
        XCTAssertEqual(second, .failed)
        XCTAssertEqual(source.runCount, 1, "a tap mid-launch must not spawn a second server")

        source.hold = false
        _ = await first.value
        XCTAssertFalse(adapter.isBusy(dashboard))
        XCTAssertTrue(source.opened.isEmpty)
    }

    // MARK: - Reuse running board

    func testLaunchReusesRunningBoardWithoutRunningUp() async {
        let url = URL(string: "http://localhost:7391/")!
        let source = FakeDashboardSource(result: .started(URL(string: "http://localhost:9999/")!))
        source.running = url
        let adapter = HarnessDashboardAdapter(source: source)
        let dashboard = HarnessDashboard.dashboards[1]

        let outcome = await adapter.launch(dashboard)

        XCTAssertEqual(outcome, .alreadyRunning(url))
        XCTAssertEqual(source.opened, [url])
        XCTAssertEqual(source.runningRoots, [dashboard.rootPath])
        XCTAssertEqual(source.runCount, 0, "a running board must be opened, not relaunched")
    }

    func testLaunchFallsThroughToUpWhenNothingServing() async {
        let url = URL(string: "http://localhost:7393/")!
        let source = FakeDashboardSource(result: .started(url))
        source.running = nil
        let adapter = HarnessDashboardAdapter(source: source)
        let dashboard = HarnessDashboard.dashboards[0]

        let outcome = await adapter.launch(dashboard)

        XCTAssertEqual(outcome, .started(url))
        XCTAssertEqual(source.runCount, 1)
        XCTAssertEqual(source.runningRoots, [dashboard.rootPath])
        XCTAssertEqual(source.runRoots, [dashboard.rootPath])
        XCTAssertEqual(source.opened, [url])
    }

    // MARK: - Arc tab reuse (opener + fallback)

    func testOpenReusesArcTabAndSuppressesFallback() async {
        let url = URL(string: "http://localhost:7391/")!
        let opener = FakeBoardBrowserOpener(succeeds: true)
        let fallback = FakeFallbackOpen()
        let source = LiveHarnessDashboardSource(
            browserOpener: opener,
            fallbackOpen: { fallback.append($0) })

        await source.open(url)

        XCTAssertEqual(opener.opened, [url])
        XCTAssertTrue(fallback.opened.isEmpty, "fallback must not run when Arc reuse succeeds")
    }

    func testOpenFallsBackWhenArcReuseMisses() async {
        let url = URL(string: "http://localhost:7393/")!
        let opener = FakeBoardBrowserOpener(succeeds: false)
        let fallback = FakeFallbackOpen()
        let source = LiveHarnessDashboardSource(
            browserOpener: opener,
            fallbackOpen: { fallback.append($0) })

        await source.open(url)

        XCTAssertEqual(opener.opened, [url])
        XCTAssertEqual(fallback.opened, [url])
    }

    func testLiveSourceDefaultInitStillCompiles() {
        _ = LiveHarnessDashboardSource()
    }

    // MARK: - launch.json

    func testParsesLaunchJSONBoardURL() {
        let json = """
        {"version":"0.0.1","configurations":[{"name":"harness-dashboard","url":"http://localhost:7391/","port":7391}]}
        """.data(using: .utf8)!
        XCTAssertEqual(
            LiveHarnessDashboardSource.launchURL(fromLaunchJSON: json)?.absoluteString,
            "http://localhost:7391/")
    }

    func testLaunchJSONWithoutBoardParsesToNil() {
        let missing = """
        {"version":"0.0.1","configurations":[{"name":"other","url":"http://localhost:3000/","port":3000}]}
        """.data(using: .utf8)!
        XCTAssertNil(LiveHarnessDashboardSource.launchURL(fromLaunchJSON: missing))
        XCTAssertNil(LiveHarnessDashboardSource.launchURL(fromLaunchJSON: Data("not json".utf8)))
        XCTAssertNil(LiveHarnessDashboardSource.launchURL(fromLaunchJSON: Data("{}".utf8)))
    }
}

// MARK: - Fake

/// `runUp` executes off the MainActor (the adapter awaits it), so every bit of
/// state shared with the test thread goes behind a lock. `open(_:)` is sync
/// and always runs on the caller's executor, but shares the lock anyway rather
/// than reasoning about which side each access lands on.
final class FakeDashboardSource: HarnessDashboardSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _result: HarnessDashboardOutcome
    private var _running: URL?
    /// When true, `runUp` waits until flipped back rather than returning.
    private var _hold = false

    private var _runCount = 0
    private var _runRoots: [String] = []
    private var _runningRoots: [String] = []
    private var _opened: [URL] = []

    var result: HarnessDashboardOutcome {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }

    var hold: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }

    var running: URL? {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }

    var runCount: Int { lock.withLock { _runCount } }
    var runRoots: [String] { lock.withLock { _runRoots } }
    var runningRoots: [String] { lock.withLock { _runningRoots } }
    var opened: [URL] { lock.withLock { _opened } }

    init(result: HarnessDashboardOutcome) {
        self._result = result
    }

    func runUp(rootPath: String) async -> HarnessDashboardOutcome {
        lock.withLock {
            _runCount += 1
            _runRoots.append(rootPath)
        }
        while hold {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return result
    }

    func runningURL(rootPath: String) async -> URL? {
        lock.withLock { _runningRoots.append(rootPath) }
        return lock.withLock { _running }
    }

    func open(_ url: URL) async {
        lock.withLock { _opened.append(url) }
    }
}

// MARK: - Fakes for Arc tab reuse

// Test-only fake: all mutable state goes behind the lock, hence @unchecked Sendable.
final class FakeBoardBrowserOpener: BoardBrowserOpener, @unchecked Sendable {
    private let lock = NSLock()
    private let succeeds: Bool
    private var _opened: [URL] = []

    var opened: [URL] { lock.withLock { _opened } }

    init(succeeds: Bool) {
        self.succeeds = succeeds
    }

    func openBoard(_ url: URL) async -> Bool {
        lock.withLock { _opened.append(url) }
        return succeeds
    }
}

// Test-only fallback capture: appended from any executor, read on the test
// thread, so all state goes behind the lock, hence @unchecked Sendable.
final class FakeFallbackOpen: @unchecked Sendable {
    private let lock = NSLock()
    private var _opened: [URL] = []

    var opened: [URL] { lock.withLock { _opened } }

    func append(_ url: URL) {
        lock.withLock { _opened.append(url) }
    }
}
