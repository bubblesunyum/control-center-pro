// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPUI
import XCTest

/// A drag measures against the screen so a view moving under the finger can't
/// feed the gesture its own output. What can go wrong is the lifecycle: an
/// anchor that never engages reports the pointer's absolute position as
/// travel, and one that outlives its gesture measures the next drag from the
/// last one's press. Both are silent on screen until someone drags by hand,
/// which is how the bug this type fixes survived several rounds.
final class ScreenDragAnchorTests: XCTestCase {
    /// A pointer the test moves, standing in for `NSEvent.mouseLocation`.
    private final class Pointer {
        var location = CGPoint(x: 500, y: 400)
        var read: () -> CGPoint { { [self] in location } }
    }

    private func anchored() -> (ScreenDragAnchor, Pointer) {
        let pointer = Pointer()
        return (ScreenDragAnchor(pointer: pointer.read), pointer)
    }

    func testFirstReadAnchorsAndTravelsNothing() {
        var (anchor, _) = anchored()
        XCTAssertFalse(anchor.isEngaged)
        XCTAssertEqual(anchor.translation(), .zero)
        XCTAssertTrue(anchor.isEngaged)
    }

    func testTravelIsTheScreenDeltaWithPanelYRunningDown() {
        var (anchor, pointer) = anchored()
        _ = anchor.translation()

        pointer.location = CGPoint(x: 530, y: 380)
        XCTAssertEqual(anchor.translation(), CGSize(width: 30, height: 20))

        // Back past the press: travel is signed, not a distance.
        pointer.location = CGPoint(x: 480, y: 430)
        XCTAssertEqual(anchor.translation(), CGSize(width: -20, height: -30))
    }

    /// The failure this guards: a gesture that forgot to reset leaves the old
    /// press behind, and the next drag opens with the whole previous journey
    /// as its first frame.
    func testResetForgetsThePressSoTheNextDragStartsFromZero() {
        var (anchor, pointer) = anchored()
        _ = anchor.translation()
        pointer.location = CGPoint(x: 800, y: 100)
        XCTAssertEqual(anchor.translation(), CGSize(width: 300, height: 300))

        anchor.reset()
        XCTAssertFalse(anchor.isEngaged)
        XCTAssertEqual(anchor.translation(), .zero)

        pointer.location = CGPoint(x: 810, y: 90)
        XCTAssertEqual(anchor.translation(), CGSize(width: 10, height: 10))
    }

    func testEngageAnchorsWithoutReportingTravel() {
        var (anchor, pointer) = anchored()
        anchor.engage()
        XCTAssertTrue(anchor.isEngaged)

        pointer.location = CGPoint(x: 512, y: 396)
        XCTAssertEqual(anchor.translation(), CGSize(width: 12, height: 4))
    }

    /// `engage()` on a live gesture must not re-anchor: a second call
    /// mid-drag would zero the travel and snap the card back to the finger.
    func testEngageOnALiveAnchorKeepsTheOriginalPress() {
        var (anchor, pointer) = anchored()
        anchor.engage()
        pointer.location = CGPoint(x: 560, y: 400)
        anchor.engage()
        XCTAssertEqual(anchor.translation(), CGSize(width: 60, height: 0))
    }
}
