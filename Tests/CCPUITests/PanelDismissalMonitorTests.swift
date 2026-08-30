// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import XCTest
@testable import CCPUI

@MainActor
final class PanelDismissalMonitorTests: XCTestCase {
    func testWatchingStopsWhenThePanelDoes() {
        let events = FakeEventMonitors()
        let monitor = PanelDismissalMonitor(monitors: events.interface) { _ in }

        monitor.start()
        XCTAssertEqual(events.installed, 2, "one monitor for the click, one for the key")

        monitor.stop()
        XCTAssertEqual(events.installed, 0)
    }

    /// The acceptance criterion for ccp-lr7.4, spelled as a test: a monitor
    /// left installed is a panel that dismisses itself for reasons the user
    /// stopped being able to see.
    func testTwentyOpensAndClosesLeaveNothingInstalled() {
        let events = FakeEventMonitors()
        let monitor = PanelDismissalMonitor(monitors: events.interface) { _ in }

        for _ in 0..<20 {
            monitor.start()
            XCTAssertLessThanOrEqual(events.installed, 2)
            monitor.stop()
        }

        XCTAssertEqual(events.installed, 0)
        XCTAssertEqual(events.added, 40, "each open installs its own pair")
        XCTAssertEqual(events.removed, 40)
    }

    func testStartingTwiceInstallsOneSet() {
        let events = FakeEventMonitors()
        let monitor = PanelDismissalMonitor(monitors: events.interface) { _ in }

        monitor.start()
        monitor.start()

        XCTAssertEqual(events.installed, 2)
        XCTAssertTrue(monitor.isWatching)
    }

    func testAClickElsewhereDismisses() {
        let events = FakeEventMonitors()
        var reasons: [PanelDismissalMonitor.Reason] = []
        let monitor = PanelDismissalMonitor(monitors: events.interface) { reasons.append($0) }

        monitor.start()
        events.sendGlobal(.init())

        XCTAssertEqual(reasons, [.clickElsewhere])
    }

    func testEscapeDismissesAndIsSwallowed() {
        let events = FakeEventMonitors()
        var reasons: [PanelDismissalMonitor.Reason] = []
        let monitor = PanelDismissalMonitor(monitors: events.interface) { reasons.append($0) }

        monitor.start()

        XCTAssertNil(events.sendLocal(keyCode: 53), "Esc is consumed by the dismissal")
        XCTAssertEqual(reasons, [.escapeKey], "so the panel can tell it apart from a click away")
    }

    func testAnyOtherKeyIsLeftAlone() {
        let events = FakeEventMonitors()
        var reasons: [PanelDismissalMonitor.Reason] = []
        let monitor = PanelDismissalMonitor(monitors: events.interface) { reasons.append($0) }

        monitor.start()

        XCTAssertNotNil(events.sendLocal(keyCode: 0), "a widget's own keystrokes still reach it")
        XCTAssertEqual(reasons, [])
    }
}

/// Stands in for `NSEvent`'s monitor API and, unlike it, will say what it is
/// holding — which is the only way to prove nothing was left behind.
@MainActor
private final class FakeEventMonitors {
    private(set) var added = 0
    private(set) var removed = 0
    private var live: Set<Int> = []

    private var globalHandler: ((NSEvent) -> Void)?
    private var localHandler: ((NSEvent) -> NSEvent?)?

    var installed: Int { live.count }

    var interface: EventMonitors {
        EventMonitors(
            addGlobal: { [self] _, handler in
                globalHandler = handler
                return token()
            },
            addLocal: { [self] _, handler in
                localHandler = handler
                return token()
            },
            remove: { [self] handle in
                guard let handle = handle as? Int else { return XCTFail("not one of ours") }
                live.remove(handle)
                removed += 1
            }
        )
    }

    private func token() -> Any {
        added += 1
        live.insert(added)
        return added
    }

    func sendGlobal(_ event: NSEvent) {
        globalHandler?(event)
    }

    func sendLocal(keyCode: UInt16) -> NSEvent? {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
        return localHandler?(event)
    }
}
