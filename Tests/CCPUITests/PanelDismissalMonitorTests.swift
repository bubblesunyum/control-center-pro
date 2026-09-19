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
        XCTAssertEqual(events.installed, 3, "one monitor for outside clicks, one for the backdrop, one for the key")

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
            XCTAssertLessThanOrEqual(events.installed, 3)
            monitor.stop()
        }

        XCTAssertEqual(events.installed, 0)
        XCTAssertEqual(events.added, 60, "each open installs its own triple")
        XCTAssertEqual(events.removed, 60)
    }

    func testStartingTwiceInstallsOneSet() {
        let events = FakeEventMonitors()
        let monitor = PanelDismissalMonitor(monitors: events.interface) { _ in }

        monitor.start()
        monitor.start()

        XCTAssertEqual(events.installed, 3)
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

    /// The permanent contract (ccp-ecye): a click on the backdrop dismisses
    /// the panel and is swallowed — returning nil so it never reaches the
    /// app below. A dismiss click that passes through is a panel nobody can
    /// see clicking buttons for the user.
    func testBackdropClickDismissesAndIsSwallowed() {
        let events = FakeEventMonitors()
        var reasons: [PanelDismissalMonitor.Reason] = []
        let monitor = PanelDismissalMonitor(
            monitors: events.interface,
            isBackdropClick: { _ in true }
        ) { reasons.append($0) }

        monitor.start()

        XCTAssertNil(events.sendBackdropClick(), "the dismiss click dies here")
        XCTAssertEqual(reasons, [.clickElsewhere])
    }

    func testContentClickPassesThroughToItsViews() {
        let events = FakeEventMonitors()
        var reasons: [PanelDismissalMonitor.Reason] = []
        let monitor = PanelDismissalMonitor(
            monitors: events.interface,
            isBackdropClick: { _ in false }
        ) { reasons.append($0) }

        monitor.start()

        XCTAssertNotNil(events.sendBackdropClick(), "a click on a card still reaches it")
        XCTAssertEqual(reasons, [])
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
    private var backdropHandler: ((NSEvent) -> NSEvent?)?
    private var keyHandler: ((NSEvent) -> NSEvent?)?

    var installed: Int { live.count }

    var interface: EventMonitors {
        EventMonitors(
            addGlobal: { [self] _, handler in
                globalHandler = handler
                return token()
            },
            addLocal: { [self] mask, handler in
                // The monitor installs two locals: the backdrop mouse watcher
                // and the Esc key watcher. Tell them apart by their masks.
                if mask.contains(.keyDown) {
                    keyHandler = handler
                } else {
                    backdropHandler = handler
                }
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

    func sendBackdropClick() -> NSEvent? {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!
        return backdropHandler?(event)
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
        return keyHandler?(event)
    }
}
