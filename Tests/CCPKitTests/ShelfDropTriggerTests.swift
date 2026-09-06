// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
@testable import CCPKit
import XCTest

/// The drop-catcher's decision policy: values in, Bool out. Every branch here
/// is the difference between a pill that appears exactly while a keepable
/// drag is in flight and one that haunts window moves.
final class ShelfDropTriggerTests: XCTestCase {
    func testFreshBumpWithDroppableContentIsActive() {
        var trigger = ShelfDropTrigger()
        trigger.beginGesture(dragChangeCount: 10, beganInDock: false, beganInOwnApp: false)

        XCTAssertTrue(trigger.isContentDrag(dragChangeCount: 11) { true })
    }

    /// The drag pasteboard retains the last drag indefinitely: without a bump
    /// past the baseline, retained content must not count.
    func testRetainedPasteboardWithoutBumpIsInactive() {
        var trigger = ShelfDropTrigger()
        trigger.beginGesture(dragChangeCount: 10, beganInDock: false, beganInOwnApp: false)

        XCTAssertFalse(trigger.isContentDrag(dragChangeCount: 10) { true })
    }

    func testNothingDroppableIsInactiveDespiteBump() {
        var trigger = ShelfDropTrigger()
        trigger.beginGesture(dragChangeCount: 10, beganInDock: false, beganInOwnApp: false)

        XCTAssertFalse(trigger.isContentDrag(dragChangeCount: 11) { false })
    }

    func testClosedGestureIsInactive() {
        var trigger = ShelfDropTrigger()

        XCTAssertFalse(trigger.isGestureOpen)
        XCTAssertFalse(trigger.isContentDrag(dragChangeCount: 99) { true })
    }

    /// Dock stacks publish before the mouse-down, so the baseline would eat
    /// them: the Dock escape skips the bump requirement.
    func testDockOriginSkipsBumpRequirement() {
        var trigger = ShelfDropTrigger()
        trigger.beginGesture(dragChangeCount: 10, beganInDock: true, beganInOwnApp: false)

        XCTAssertTrue(trigger.isContentDrag(dragChangeCount: 10) { true })
    }

    /// A gesture that started in one of our own windows is a drag *out of*
    /// the shelf; our freshly published content must not summon the pill.
    func testOwnAppOriginSuppressesDespiteBump() {
        var trigger = ShelfDropTrigger()
        trigger.beginGesture(dragChangeCount: 10, beganInDock: false, beganInOwnApp: true)

        XCTAssertFalse(trigger.isContentDrag(dragChangeCount: 99) { true })
    }

    /// Ending absorbs what the finished drag left retained, so the next
    /// gesture baselines past it.
    func testEndAbsorbsRetainedContent() {
        var trigger = ShelfDropTrigger()
        trigger.beginGesture(dragChangeCount: 10, beganInDock: false, beganInOwnApp: false)
        trigger.endGesture(dragChangeCount: 12)

        XCTAssertFalse(trigger.isGestureOpen)
        trigger.beginGesture(dragChangeCount: 12, beganInDock: false, beganInOwnApp: false)
        XCTAssertFalse(trigger.isContentDrag(dragChangeCount: 12) { true })
        XCTAssertTrue(trigger.isContentDrag(dragChangeCount: 13) { true })
    }

    /// A synthesized event is made by this process, so it genuinely reads as
    /// our own — which is exactly the branch a drag-out's observed mouse-down
    /// takes. The window-server branches (Dock / foreign pid) are
    /// system-dependent and stay covered by the controller's stubbed origin.
    func testSyntheticEventResolvesOwnApp() {
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

        XCTAssertEqual(ShelfDropTrigger.gestureOrigin(event), .ownApp)
    }
}
