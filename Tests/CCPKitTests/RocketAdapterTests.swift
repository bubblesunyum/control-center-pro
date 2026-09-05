// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import AppKit
import XCTest

@MainActor
final class RocketAdapterTests: XCTestCase {
    // MARK: - State

    func testInitPublishesSourceState() {
        let source = FakeRocketSource(isInstalled: true, isRunning: false)
        let adapter = RocketAdapter(source: source, notifications: NotificationCenter())
        XCTAssertTrue(adapter.isInstalled)
        XCTAssertFalse(adapter.isRunning)
    }

    func testRefreshPicksUpExternalChanges() {
        let source = FakeRocketSource(isInstalled: true, isRunning: true)
        let adapter = RocketAdapter(source: source, notifications: NotificationCenter())
        source.isRunning = false
        adapter.refresh()
        XCTAssertFalse(adapter.isRunning)
    }

    func testLaunchAndQuitWhileOpenReachAdapter() {
        let center = NotificationCenter()
        let source = FakeRocketSource(isInstalled: true, isRunning: true)
        let adapter = RocketAdapter(source: source, notifications: center)
        adapter.activate()

        source.isRunning = false
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        XCTAssertFalse(adapter.isRunning)

        source.isRunning = true
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        XCTAssertTrue(adapter.isRunning)
    }

    func testNotificationsIgnoredAfterDeactivate() {
        let center = NotificationCenter()
        let source = FakeRocketSource(isInstalled: true, isRunning: true)
        let adapter = RocketAdapter(source: source, notifications: center)
        adapter.activate()
        adapter.deactivate()

        source.isRunning = false
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        XCTAssertTrue(adapter.isRunning, "a shut panel must watch nothing")
    }

    // MARK: - showMenu

    func testShowMenuWhenNotInstalledTouchesNothing() async {
        let source = FakeRocketSource(isInstalled: false, isRunning: false)
        let adapter = RocketAdapter(source: source, notifications: NotificationCenter())
        let outcome = await adapter.showMenu()
        XCTAssertEqual(outcome, .notInstalled)
        XCTAssertEqual(source.launchCount, 0)
        XCTAssertEqual(source.pressCount, 0)
    }

    func testShowMenuLaunchesWhenStopped() async {
        let source = FakeRocketSource(isInstalled: true, isRunning: false)
        source.launchRunsRocket = true
        let adapter = RocketAdapter(source: source, notifications: NotificationCenter())
        let outcome = await adapter.showMenu()
        XCTAssertEqual(outcome, .launched)
        XCTAssertEqual(source.launchCount, 1)
        XCTAssertEqual(source.pressCount, 0, "a stopped Rocket has no menu to press")
        XCTAssertTrue(adapter.isRunning)
    }

    func testShowMenuPressesWhenRunning() async {
        let source = FakeRocketSource(isInstalled: true, isRunning: true)
        let adapter = RocketAdapter(source: source, notifications: NotificationCenter())
        let outcome = await adapter.showMenu()
        XCTAssertEqual(outcome, .shown)
        XCTAssertEqual(source.pressCount, 1)
        XCTAssertEqual(source.launchCount, 0)
    }

    func testShowMenuPromptsOnceWhenUntrusted() async {
        let source = FakeRocketSource(isInstalled: true, isRunning: true)
        source.pressResult = .untrusted
        let adapter = RocketAdapter(source: source, notifications: NotificationCenter())
        let first = await adapter.showMenu()
        let second = await adapter.showMenu()
        XCTAssertEqual(first, .needsAccessibility)
        XCTAssertEqual(second, .needsAccessibility)
        XCTAssertEqual(source.trustRequestCount, 1, "the system prompt is the only route to a grant, and one is enough")
    }

    func testGrantAfterPromptPressesWithoutReprompting() async {
        let source = FakeRocketSource(isInstalled: true, isRunning: true)
        source.pressResult = .untrusted
        let adapter = RocketAdapter(source: source, notifications: NotificationCenter())
        let denied = await adapter.showMenu()
        XCTAssertEqual(denied, .needsAccessibility)
        source.pressResult = .pressed
        let granted = await adapter.showMenu()
        XCTAssertEqual(granted, .shown)
        XCTAssertEqual(source.trustRequestCount, 1, "a grant takes effect on the next press with no second prompt")
    }

    func testShowMenuLaunchesOnRacedQuit() async {
        let source = FakeRocketSource(isInstalled: true, isRunning: true)
        source.pressResult = .notRunning
        source.launchRunsRocket = true
        let adapter = RocketAdapter(source: source, notifications: NotificationCenter())
        let outcome = await adapter.showMenu()
        XCTAssertEqual(outcome, .launched)
        XCTAssertEqual(source.launchCount, 1)
    }

    func testShowMenuFailsSoftWhenItemMissing() async {
        let source = FakeRocketSource(isInstalled: true, isRunning: true)
        source.pressScript = [.itemNotFound, .itemNotFound]
        let adapter = RocketAdapter(source: source, notifications: NotificationCenter())
        let outcome = await adapter.showMenu()
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(source.pressCount, 2, "a fresh launch may not have its status item yet")
    }

    func testShowMenuRetriesPressOnce() async {
        let source = FakeRocketSource(isInstalled: true, isRunning: true)
        source.pressScript = [.itemNotFound, .pressed]
        let adapter = RocketAdapter(source: source, notifications: NotificationCenter())
        let outcome = await adapter.showMenu()
        XCTAssertEqual(outcome, .shown)
        XCTAssertEqual(source.pressCount, 2)
    }

    func testShowMenuLaunchesWhenQuitDuringPress() async {
        let source = FakeRocketSource(isInstalled: true, isRunning: true)
        source.pressScript = [.itemNotFound]
        source.stopRunningWhenPressed = true
        source.launchRunsRocket = true
        let adapter = RocketAdapter(source: source, notifications: NotificationCenter())
        let outcome = await adapter.showMenu()
        XCTAssertEqual(outcome, .launched)
        XCTAssertEqual(source.launchCount, 1)
    }

    // MARK: - Status item matching

    func testMatcherAcceptsRocketStatusItem() {
        XCTAssertTrue(LiveRocketSource.isStatusItem(description: "status menu", title: nil, role: "AXMenuBarItem"))
    }

    func testMatcherRejectsAppMenuItems() {
        XCTAssertFalse(LiveRocketSource.isStatusItem(description: nil, title: "Preferences…", role: "AXMenuBarItem"))
        XCTAssertFalse(LiveRocketSource.isStatusItem(description: "status menu", title: nil, role: "AXMenu"))
        XCTAssertFalse(LiveRocketSource.isStatusItem(description: "clock", title: nil, role: "AXMenuBarItem"))
    }
}

// MARK: - Fake

/// Plain vars are safe unchecked: every access runs on the test's MainActor.
final class FakeRocketSource: RocketSource, @unchecked Sendable {
    var isInstalled: Bool
    var isRunning: Bool
    var isAccessibilityTrusted = true
    /// Whether `launch()` flips the app to running, like a real launch.
    var launchRunsRocket = false
    /// Scripted press results, consumed in order; falls back to `pressResult`.
    var pressScript: [RocketPressResult] = []
    var pressResult: RocketPressResult = .pressed
    /// Whether pressing stops the app, like a quit racing the press.
    var stopRunningWhenPressed = false

    var launchCount = 0
    var trustRequestCount = 0
    var pressCount = 0

    init(isInstalled: Bool, isRunning: Bool) {
        self.isInstalled = isInstalled
        self.isRunning = isRunning
    }

    func launch() {
        launchCount += 1
        if launchRunsRocket { isRunning = true }
    }

    func requestAccessibilityTrust() {
        trustRequestCount += 1
    }

    func pressStatusMenu() -> RocketPressResult {
        pressCount += 1
        if stopRunningWhenPressed { isRunning = false }
        if !pressScript.isEmpty { return pressScript.removeFirst() }
        return pressResult
    }
}
