// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import Foundation
import XCTest

@MainActor
final class HarnessDashboardAdapterTests: XCTestCase {
    // MARK: - Catalogue

    func testDashboardsListsTheFourHarnessesInOrder() {
        let ids = HarnessDashboard.dashboards.map(\.id)
        XCTAssertEqual(ids, ["psymail-mini", "control-center-pro", "bb-kit", "fusebox-migration"])
    }

    func testDashboardsPointAtFixedSiblingCheckouts() {
        let roots = HarnessDashboard.dashboards.map(\.rootPath)
        XCTAssertEqual(roots, [
            "/Users/bubbles/dev/psymail-mini",
            "/Users/bubbles/dev/control-center-pro",
            "/Users/bubbles/dev/bb-kit",
            "/Users/bubbles/dev/fusebox-migration",
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
}

// MARK: - Fake

/// `runUp` executes off the MainActor (the adapter awaits it), so every bit of
/// state shared with the test thread goes behind a lock. `open(_:)` is sync
/// and always runs on the caller's executor, but shares the lock anyway rather
/// than reasoning about which side each access lands on.
final class FakeDashboardSource: HarnessDashboardSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _result: HarnessDashboardOutcome
    /// When true, `runUp` waits until flipped back rather than returning.
    private var _hold = false

    private var _runCount = 0
    private var _runRoots: [String] = []
    private var _opened: [URL] = []

    var result: HarnessDashboardOutcome {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }

    var hold: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }

    var runCount: Int { lock.withLock { _runCount } }
    var runRoots: [String] { lock.withLock { _runRoots } }
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

    func open(_ url: URL) {
        lock.withLock { _opened.append(url) }
    }
}
