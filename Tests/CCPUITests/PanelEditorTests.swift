// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI
import XCTest
@testable import CCPUI

/// Where a drag would land. The frames here are the shape of a real panel —
/// 240pt lanes, 12pt apart — because the arithmetic is only interesting
/// against the geometry it actually runs on.
@MainActor
final class PanelEditorTests: XCTestCase {
    private let a: WidgetID = "a"
    private let b: WidgetID = "b"
    private let c: WidgetID = "c"

    private func editor(zones: [PanelEditor.DropZone]) -> PanelEditor {
        let editor = PanelEditor()
        editor.zones = zones
        return editor
    }

    /// Lane 0 holds a (top) and b (below it); lane 1 holds c.
    private var twoLanes: [PanelEditor.DropZone] {
        [
            .init(id: a, lane: 0, frame: CGRect(x: 12, y: 12, width: 240, height: 132)),
            .init(id: b, lane: 0, frame: CGRect(x: 12, y: 156, width: 240, height: 132)),
            .init(id: c, lane: 1, frame: CGRect(x: 264, y: 12, width: 240, height: 232)),
        ]
    }

    /// An editor with `id` already in the air and the finger at `point`.
    private func dragging(_ id: WidgetID, to point: CGPoint, laneCapacity: Int = .max) -> PanelEditor {
        let editor = editor(zones: twoLanes)
        editor.laneCapacity = laneCapacity
        editor.startEditing()
        editor.lift(id, at: CGPoint(x: 20, y: 20))
        editor.drag(to: point)
        return editor
    }

    func testAboveEverythingInALaneLandsFirst() {
        let landing = dragging(c, to: CGPoint(x: 100, y: 20)).landing(laneCount: 2)

        XCTAssertEqual(landing, .into(lane: 0, index: 0))
    }

    func testBelowEverythingInALaneLandsLast() {
        let landing = dragging(c, to: CGPoint(x: 100, y: 400)).landing(laneCount: 2)

        XCTAssertEqual(landing, .into(lane: 0, index: 2))
    }

    /// The card in the air doesn't count itself, which is what makes dragging
    /// one down its own lane land it where the finger is rather than one short.
    func testACardDoesNotCountItsOwnPlace() {
        let landing = dragging(a, to: CGPoint(x: 100, y: 400)).landing(laneCount: 2)

        XCTAssertEqual(landing, .into(lane: 0, index: 1), "b is the only card it would sit below")
    }

    func testTheLaneUnderTheFingerIsTheOneItLandsIn() {
        let landing = dragging(a, to: CGPoint(x: 300, y: 20)).landing(laneCount: 2)

        XCTAssertEqual(landing, .into(lane: 1, index: 0))
    }

    /// The panel is pinned to the right of the screen and grows leftward, so
    /// the column a drag opens is the new leftmost one.
    func testLeftOfEverythingOpensANewLeadingLane() {
        let landing = dragging(a, to: CGPoint(x: 2, y: 20), laneCapacity: 4).landing(laneCount: 2)

        XCTAssertEqual(landing, .newLane(at: 0))
    }

    /// ccp-p6g: the panel is anchored top-right and doesn't scroll, so a lane
    /// the display can't show is one the user would lose things in.
    func testNoNewLaneWhenTheDisplayIsFull() {
        let editor = dragging(a, to: CGPoint(x: 2, y: 20), laneCapacity: 2)

        XCTAssertNil(editor.landing(laneCount: 2))
        XCTAssertFalse(editor.isOfferingNewLane(laneCount: 2))
    }

    func testTheNewLaneIsOfferedForTheWholeDragNotJustOverIt() {
        let editor = dragging(a, to: CGPoint(x: 300, y: 20), laneCapacity: 4)

        XCTAssertTrue(editor.isOfferingNewLane(laneCount: 2))
    }

    func testNothingIsOfferedWhenNothingIsInTheAir() {
        XCTAssertFalse(editor(zones: twoLanes).isOfferingNewLane(laneCount: 2))
    }

    func testALandingNeedsSomethingInTheAir() {
        XCTAssertNil(editor(zones: twoLanes).landing(laneCount: 2))
    }

    func testEndingEditModePutsDownWhateverWasInTheAir() {
        let editor = dragging(a, to: CGPoint(x: 100, y: 100))
        XCTAssertNotNil(editor.lifted)

        editor.stopEditing()

        XCTAssertNil(editor.lifted)
        XCTAssertFalse(editor.isEditing)
    }

    func testLiftingSomethingWithNoFrameYetDoesNothing() {
        let editor = editor(zones: [])

        editor.lift(a, at: .zero)

        XCTAssertNil(editor.lifted)
    }

    func testTheGrabPointIsWhereTheCardWasHeld() {
        let editor = editor(zones: twoLanes)

        editor.lift(b, at: CGPoint(x: 42, y: 200))

        XCTAssertEqual(editor.lifted?.grab, CGSize(width: 30, height: 44))
    }
}

@MainActor
final class LaneCapacityTests: XCTestCase {
    func testALaneAndItsGutterHaveToFit() {
        XCTAssertEqual(Layout.laneCapacity(inWidth: 1440), 5)
        XCTAssertEqual(Layout.laneCapacity(inWidth: 800), 3)
    }

    /// A display too narrow for one lane still gets one: a panel with no lanes
    /// is not an improvement on a panel that is slightly too wide.
    func testEvenAnImpossiblyNarrowDisplayGetsOneLane() {
        XCTAssertEqual(Layout.laneCapacity(inWidth: 100), 1)
    }
}
