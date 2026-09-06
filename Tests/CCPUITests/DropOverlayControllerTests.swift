// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
@testable import CCPUI
import XCTest

/// The drop-catcher's state machine, driven the way a real drag would drive
/// it — synthetic mouse events through the monitor seam, scripted pasteboard
/// and button reads — with a fake panel recording show/hide instead of
/// ordering real windows.
@MainActor
final class DropOverlayControllerTests: XCTestCase {
    private var events: FakeOverlayMonitors!
    private var panel: FakeOverlayPanel!
    private var changeCount = 10
    private var droppable = false
    private var buttonDown = false
    private var suppressed = false
    private var origin: DropOverlayOrigin = .elsewhere
    private var controller: DropOverlayController!

    override func setUp() {
        super.setUp()
        events = FakeOverlayMonitors()
        let fakePanel = FakeOverlayPanel()
        panel = fakePanel
        changeCount = 10
        droppable = false
        buttonDown = false
        suppressed = false
        origin = .elsewhere
        controller = DropOverlayController(
            monitors: events.interface,
            makePanel: { _ in fakePanel },
            statusFrame: { NSRect(x: 100, y: 900, width: 22, height: 22) },
            isSuppressed: { [weak self] in self?.suppressed ?? false },
            dragChangeCount: { [weak self] in self?.changeCount ?? 0 },
            hasDroppableContent: { [weak self] in self?.droppable ?? false },
            isLeftButtonDown: { [weak self] in self?.buttonDown ?? false },
            gestureOrigin: { [weak self] _ in self?.origin ?? .elsewhere },
            tickDelay: 0.9,
            endDelay: 0.15
        )
    }

    override func tearDown() {
        controller.stop()
        controller = nil
        super.tearDown()
    }

    func testStartInstallsOneMonitorAndStopRemovesIt() {
        controller.start()
        XCTAssertEqual(events.installed, 1)

        controller.stop()
        XCTAssertEqual(events.installed, 0)
    }

    func testStartingTwiceInstallsOneSet() {
        controller.start()
        controller.start()

        XCTAssertEqual(events.installed, 1)
    }

    /// The whole feature in four events: down, dragged with fresh droppable
    /// content, up, end — with the show anchored to the status frame.
    func testQualifyingDragShowsPillAnchoredToStatusFrame() {
        controller.start()
        controller.handleMonitorEvent(mouse(.leftMouseDown))
        droppable = true
        changeCount = 11
        controller.handleMonitorEvent(mouse(.leftMouseDragged))

        XCTAssertTrue(controller.isShowing)
        let anchor: NSRect? = NSRect(x: 100, y: 900, width: 22, height: 22)
        XCTAssertEqual(panel.shownAnchors, [anchor])
    }

    func testRetainedPasteboardWithoutBumpNeverShows() {
        controller.start()
        controller.handleMonitorEvent(mouse(.leftMouseDown))
        droppable = true
        controller.handleMonitorEvent(mouse(.leftMouseDragged))

        XCTAssertFalse(controller.isShowing)
        XCTAssertTrue(panel.shownAnchors.isEmpty)
    }

    func testNonDroppableDragNeverShows() {
        controller.start()
        controller.handleMonitorEvent(mouse(.leftMouseDown))
        changeCount = 11
        controller.handleMonitorEvent(mouse(.leftMouseDragged))

        XCTAssertFalse(controller.isShowing)
    }

    func testSuppressedDragStaysHidden() {
        suppressed = true
        controller.start()
        controller.handleMonitorEvent(mouse(.leftMouseDown))
        droppable = true
        changeCount = 11
        controller.handleMonitorEvent(mouse(.leftMouseDragged))

        XCTAssertFalse(controller.isShowing)
    }

    /// Suppression can start mid-drag (the main panel opened via hotkey): the
    /// pill steps aside, and comes back if suppression lifts mid-drag.
    func testSuppressionMidDragHidesAndLiftingReshows() {
        controller.start()
        controller.handleMonitorEvent(mouse(.leftMouseDown))
        droppable = true
        changeCount = 11
        controller.handleMonitorEvent(mouse(.leftMouseDragged))
        XCTAssertTrue(controller.isShowing)

        suppressed = true
        changeCount = 12
        controller.handleMonitorEvent(mouse(.leftMouseDragged))
        XCTAssertFalse(controller.isShowing)
        XCTAssertEqual(panel.hideCount, 1)

        suppressed = false
        changeCount = 13
        controller.handleMonitorEvent(mouse(.leftMouseDragged))
        XCTAssertTrue(controller.isShowing)
    }

    func testMouseUpWithoutDropHidesAfterEndWork() {
        showQualifyingDrag()
        controller.handleMonitorEvent(mouse(.leftMouseUp))

        // The delay lets a landing drop claim the pill first.
        XCTAssertTrue(controller.isShowing)
        controller.endWorkFired()

        XCTAssertFalse(controller.isShowing)
        XCTAssertEqual(panel.hideCount, 1)
        XCTAssertFalse(controller.justCaught)
    }

    /// One accept per gesture: tick, hide, and no re-show until a new drag —
    /// the no-stick-around rule, spelled as a test.
    func testAcceptTicksThenHidesWithNoReshowUntilNextGesture() {
        showQualifyingDrag()
        controller.didAcceptDrop()

        XCTAssertTrue(controller.justCaught)
        XCTAssertTrue(controller.isShowing)
        controller.tickWorkFired()
        XCTAssertFalse(controller.justCaught)
        XCTAssertFalse(controller.isShowing)

        // The button is still down and content still flows: stays hidden.
        droppable = true
        changeCount = 12
        controller.handleMonitorEvent(mouse(.leftMouseDragged))
        XCTAssertFalse(controller.isShowing)
        XCTAssertEqual(panel.shownAnchors.count, 1)

        // A new gesture resets the rule.
        controller.handleMonitorEvent(mouse(.leftMouseUp))
        controller.endWorkFired()
        controller.handleMonitorEvent(mouse(.leftMouseDown))
        changeCount = 13
        controller.handleMonitorEvent(mouse(.leftMouseDragged))
        XCTAssertTrue(controller.isShowing)
    }

    func testWatchdogEndsGestureWhenButtonIsUp() {
        showQualifyingDrag()
        buttonDown = false
        controller.watchdogFired()
        controller.endWorkFired()

        XCTAssertFalse(controller.isShowing)
    }

    func testWatchdogLeavesLiveDragAlone() {
        showQualifyingDrag()
        buttonDown = true
        controller.watchdogFired()

        XCTAssertTrue(controller.isShowing)
    }

    /// A stale tick must not fire into the next drag: the new gesture cancels
    /// the previous drop's hide.
    func testStaleTickCannotHideNextDrag() async throws {
        let fakePanel = panel!
        let quick = DropOverlayController(
            monitors: events.interface,
            makePanel: { _ in fakePanel },
            statusFrame: { nil },
            isSuppressed: { false },
            dragChangeCount: { [weak self] in self?.changeCount ?? 0 },
            hasDroppableContent: { [weak self] in self?.droppable ?? false },
            isLeftButtonDown: { [weak self] in self?.buttonDown ?? false },
            gestureOrigin: { [weak self] _ in self?.origin ?? .elsewhere },
            tickDelay: 0.05,
            endDelay: 0.0
        )
        quick.start()
        defer { quick.stop() }

        changeCount = 10
        droppable = true
        quick.handleMonitorEvent(mouse(.leftMouseDown))
        changeCount = 11
        quick.handleMonitorEvent(mouse(.leftMouseDragged))
        XCTAssertTrue(quick.isShowing)
        quick.didAcceptDrop()

        // The next drag starts before the 0.05s tick fires.
        quick.handleMonitorEvent(mouse(.leftMouseDown))
        changeCount = 12
        quick.handleMonitorEvent(mouse(.leftMouseDragged))
        XCTAssertTrue(quick.isShowing)

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(quick.isShowing, "cancelled tick fired into the new drag")
    }

    /// Suppression can start mid-drag under a stationary mouse (hotkey): the
    /// watchdog re-reads it, so the pill steps aside with no dragged event.
    func testWatchdogHidesSuppressedPillWithoutMouseMovement() {
        showQualifyingDrag()
        suppressed = true
        buttonDown = true
        controller.watchdogFired()

        XCTAssertFalse(controller.isShowing)
        XCTAssertEqual(panel.hideCount, 1)
    }

    func testAcceptWhileSuppressedSetsTickWithoutShowing() {
        suppressed = true
        controller.start()
        controller.handleMonitorEvent(mouse(.leftMouseDown))
        droppable = true
        changeCount = 11
        controller.handleMonitorEvent(mouse(.leftMouseDragged))
        XCTAssertFalse(controller.isShowing)

        controller.didAcceptDrop()
        XCTAssertTrue(controller.justCaught)
        XCTAssertFalse(controller.isShowing)
        controller.tickWorkFired()
        XCTAssertFalse(controller.justCaught)
    }

    func testStopHidesPillAndClearsState() {
        showQualifyingDrag()
        controller.stop()

        XCTAssertFalse(controller.isShowing)
        XCTAssertFalse(controller.justCaught)
        XCTAssertEqual(panel.hideCount, 1)
        XCTAssertEqual(events.installed, 0)

        // A later start inherits no stale gesture: the stop absorbed the
        // retained count as the new baseline.
        controller.start()
        controller.handleMonitorEvent(mouse(.leftMouseDragged))
        XCTAssertFalse(controller.isShowing)
        changeCount = 12
        controller.handleMonitorEvent(mouse(.leftMouseDragged))
        XCTAssertTrue(controller.isShowing)
    }

    /// The production path for a drag out of the shelf: the global monitor
    /// never sees the mouse-down inside our own window, so the gesture opens
    /// late on its first dragged event and the baseline absorbs our freshly
    /// published content.
    func testLateOpenedGestureBaselinesPastRetainedContent() {
        controller.start()
        droppable = true
        controller.handleMonitorEvent(mouse(.leftMouseDragged))

        XCTAssertFalse(controller.isShowing)
        XCTAssertTrue(panel.shownAnchors.isEmpty)
    }

    /// The drop's mouse-up lands in our own pill, invisible to the monitor:
    /// only the button poll closes the gesture, and the tick still owns the
    /// hide.
    func testWatchdogClosesGestureAfterDropWithoutMouseUp() {
        showQualifyingDrag()
        controller.didAcceptDrop()

        buttonDown = false
        controller.watchdogFired()
        controller.endWorkFired()
        XCTAssertTrue(controller.isShowing)
        XCTAssertTrue(controller.justCaught)

        controller.tickWorkFired()
        XCTAssertFalse(controller.isShowing)
        XCTAssertFalse(controller.justCaught)
    }

    /// A gesture that opened in one of our own windows is a drag *out of*
    /// the shelf: our freshly published content must not summon the pill.
    func testOwnAppOriginNeverShows() {
        origin = .ownApp
        controller.start()
        controller.handleMonitorEvent(mouse(.leftMouseDown))
        droppable = true
        changeCount = 99
        controller.handleMonitorEvent(mouse(.leftMouseDragged))

        XCTAssertFalse(controller.isShowing)
        XCTAssertTrue(panel.shownAnchors.isEmpty)
    }

    /// Dock stacks publish before the mouse-down: no bump needed.
    func testDockOriginShowsWithoutBump() {
        origin = .dock
        controller.start()
        controller.handleMonitorEvent(mouse(.leftMouseDown))
        droppable = true
        controller.handleMonitorEvent(mouse(.leftMouseDragged))

        XCTAssertTrue(controller.isShowing)
    }

    // MARK: - Helpers

    private func showQualifyingDrag() {
        controller.start()
        controller.handleMonitorEvent(mouse(.leftMouseDown))
        droppable = true
        changeCount = 11
        controller.handleMonitorEvent(mouse(.leftMouseDragged))
        XCTAssertTrue(controller.isShowing)
    }

    private func mouse(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!
    }
}

/// Same seam as `PanelDismissalMonitor`'s fake: the invariant worth proving is
/// about the calls made, and `NSEvent` will not say what it is holding.
private final class FakeOverlayMonitors {
    private(set) var added = 0
    private(set) var removed = 0
    private var live: Set<Int> = []
    private var globalHandler: ((NSEvent) -> Void)?

    var installed: Int { live.count }

    var interface: EventMonitors {
        EventMonitors(
            addGlobal: { [self] _, handler in
                globalHandler = handler
                return token()
            },
            addLocal: { _, _ in nil },
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

    func send(_ event: NSEvent) {
        globalHandler?(event)
    }
}

private final class FakeOverlayPanel: DropOverlayPanel {
    var shownAnchors: [NSRect?] = []
    private(set) var hideCount = 0

    func show(anchoredTo anchor: NSRect?, content: DropOverlayRoot) {
        shownAnchors.append(anchor)
    }

    func hide() {
        hideCount += 1
    }
}
