// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPKit

/// The verbs edit mode calls. They run on ids alone, which is what lets a lane
/// holding a widget this build doesn't have reorder like any other.
@MainActor
final class PanelLayoutRearrangingTests: XCTestCase {
    private let a: WidgetID = "a"
    private let b: WidgetID = "b"
    private let c: WidgetID = "c"

    func testMovingWithinALane() {
        let layout = PanelLayout([[a, b, c]])

        XCTAssertEqual(layout.moving(a, toLane: 0, at: 2).lanes, [[b, c, a]])
    }

    /// The index is read after the card is lifted out, so dragging one to the
    /// bottom of its own lane lands it at the bottom rather than one short.
    func testMovingDownItsOwnLaneUsesThePostLiftIndex() {
        let layout = PanelLayout([[a, b, c]])

        XCTAssertEqual(layout.moving(a, toLane: 0, at: 1).lanes, [[b, a, c]])
    }

    func testMovingToAnotherLane() {
        let layout = PanelLayout([[a, b], [c]])

        XCTAssertEqual(layout.moving(a, toLane: 1, at: 0).lanes, [[b], [a, c]])
    }

    func testMovingToTheLanePastTheEndMakesOne() {
        let layout = PanelLayout([[a, b]])

        XCTAssertEqual(layout.moving(a, toLane: 1, at: 0).lanes, [[b], [a]])
    }

    func testEmptyingALaneClosesIt() {
        let layout = PanelLayout([[a], [b]])

        XCTAssertEqual(
            layout.moving(a, toLane: 1, at: 0).lanes,
            [[a, b]],
            "the lane it left has nothing in it and stops existing"
        )
    }

    func testMovingTheOnlyWidgetToANewLaneChangesNothing() {
        let layout = PanelLayout([[a]])

        XCTAssertEqual(
            layout.moving(a, toLane: 1, at: 0).lanes,
            [[a]],
            "the lane it left closes up behind it, which is the lane it arrived in"
        )
    }

    func testAnIndexPastTheEndOfALaneLandsAtTheEnd() {
        let layout = PanelLayout([[a, b]])

        XCTAssertEqual(layout.moving(a, toLane: 0, at: 99).lanes, [[b, a]])
    }

    func testALaneThatIsNotThereIsNotADrop() {
        let layout = PanelLayout([[a, b]])

        XCTAssertEqual(layout.moving(a, toLane: 7, at: 0), layout)
        XCTAssertEqual(layout.moving(a, toLane: -1, at: 0), layout)
    }

    func testMovingAWidgetTheLayoutDoesNotPlaceChangesNothing() {
        let layout = PanelLayout([[a]])

        XCTAssertEqual(layout.moving(b, toLane: 0, at: 0), layout)
    }

    func testReorderingAroundAWidgetThisBuildDoesNotHave() {
        let absent: WidgetID = "widget-from-a-newer-build"
        let layout = PanelLayout([[a, absent, b]])

        XCTAssertEqual(
            layout.moving(b, toLane: 0, at: 1).lanes,
            [[a, b, absent]],
            "an unresolvable id is still a position in the lane"
        )
    }

    func testRemoving() {
        let layout = PanelLayout([[a, b], [c]])

        XCTAssertEqual(layout.removing(b).lanes, [[a], [c]])
    }

    func testRemovingTheLastWidgetLeavesOneEmptyLane() {
        XCTAssertEqual(PanelLayout([[a]]).removing(a), .empty)
    }

    func testRemovingSomethingThatIsNotThereChangesNothing() {
        let layout = PanelLayout([[a]])

        XCTAssertEqual(layout.removing(c), layout)
    }

    func testPosition() {
        let layout = PanelLayout([[a], [b, c]])

        XCTAssertEqual(layout.position(of: c)?.lane, 1)
        XCTAssertEqual(layout.position(of: c)?.index, 1)
        XCTAssertNil(layout.position(of: "nowhere"))
    }
}

/// Opening a lane, which is the drop that makes the panel a column wider.
@MainActor
final class PanelLayoutNewLaneTests: XCTestCase {
    private let a: WidgetID = "a"
    private let b: WidgetID = "b"
    private let c: WidgetID = "c"

    func testANewLeadingLane() {
        let layout = PanelLayout([[a, b], [c]])

        XCTAssertEqual(layout.moving(c, toNewLaneAt: 0).lanes, [[c], [a, b]])
    }

    func testANewLaneAtTheEnd() {
        let layout = PanelLayout([[a, b]])

        XCTAssertEqual(layout.moving(a, toNewLaneAt: 1).lanes, [[b], [a]])
    }

    func testTheLaneItLeftClosesUpBehindIt() {
        let layout = PanelLayout([[a], [b]])

        XCTAssertEqual(
            layout.moving(a, toNewLaneAt: 0).lanes,
            [[a], [b]],
            "one lane opened, one emptied and closed — the count is unchanged"
        )
    }

    func testAWidgetTheLayoutDoesNotPlaceOpensNothing() {
        let layout = PanelLayout([[a]])

        XCTAssertEqual(layout.moving(b, toNewLaneAt: 0), layout)
    }

    func testALanePositionThatIsNotThere() {
        let layout = PanelLayout([[a, b]])

        XCTAssertEqual(layout.moving(a, toNewLaneAt: 9), layout)
        XCTAssertEqual(layout.moving(a, toNewLaneAt: -1), layout)
    }
}

/// Adding, which is the gallery's whole vocabulary.
@MainActor
final class PanelLayoutAddingTests: XCTestCase {
    private let a: WidgetID = "a"
    private let b: WidgetID = "b"
    private let c: WidgetID = "c"

    func testItLandsInTheLaneCarryingTheLeast() {
        let layout = PanelLayout([[a, b], [c]])

        XCTAssertEqual(layout.adding("d").lanes, [[a, b], [c, "d"]])
    }

    func testTheFirstOfTwoEqualLanesWins() {
        let layout = PanelLayout([[a], [b]])

        XCTAssertEqual(layout.adding(c).lanes, [[a, c], [b]])
    }

    func testAddingToAnEmptyPanel() {
        XCTAssertEqual(PanelLayout.empty.adding(a).lanes, [[a]])
    }

    func testAWidgetAlreadyOnThePanelIsNotAddedTwice() {
        let layout = PanelLayout([[a, b]])

        XCTAssertEqual(layout.adding(a), layout)
    }
}
