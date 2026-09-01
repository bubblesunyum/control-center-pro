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
    /// Lift where the card actually is so `grab` is realistic (≈10pt inside);
    /// otherwise a fixed `20,20` for `c` at `264,12` yields a -244pt grab and
    /// the ghost's center is lanes away from the fingertip.
    private func dragging(_ id: WidgetID, to point: CGPoint, laneCapacity: Int = .max) -> PanelEditor {
        let editor = editor(zones: twoLanes)
        editor.laneCapacity = laneCapacity
        editor.startEditing()
        if let zone = twoLanes.first(where: { $0.id == id }) {
            editor.lift(id, at: CGPoint(x: zone.frame.minX + 8, y: zone.frame.minY + 8))
        } else {
            editor.lift(id, at: CGPoint(x: 20, y: 20))
        }
        editor.drag(to: point)
        return editor
    }

    func testAboveEverythingInALaneLandsFirst() {
        // Ghost center, not fingertip, decides the index — fingertip must be
        // ~half a card above the first mid to have the ghost above it.
        let landing = dragging(c, to: CGPoint(x: 100, y: -40)).landing(laneCount: 2)

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
        // New lane triggers when ghost center is left of every card.
        let landing = dragging(a, to: CGPoint(x: -110, y: 20), laneCapacity: 4).landing(laneCount: 2)

        XCTAssertEqual(landing, .newLane(at: 0))
    }

    /// ccp-p6g: the panel is anchored top-right and doesn't scroll, so a lane
    /// the display can't show is one the user would lose things in.
    func testNoNewLaneWhenTheDisplayIsFull() {
        let editor = dragging(a, to: CGPoint(x: -110, y: 20), laneCapacity: 2)

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

    func testLandingFollowsGhostCenterNotFingertip() {
        // Same fingertip with different grabs should land differently when
        // the decision follows the ghost's center.
        let finger = CGPoint(x: 100, y: 200)
        // Grab near top-left of `a`
        let topEditor = editor(zones: twoLanes)
        topEditor.startEditing()
        topEditor.lift(a, at: CGPoint(x: 14, y: 14)) // grab 2,2
        topEditor.drag(to: finger)
        let topLanding = topEditor.landing(laneCount: 2)

        // Grab near bottom-right of `a`
        let bottomEditor = editor(zones: twoLanes)
        bottomEditor.startEditing()
        bottomEditor.lift(a, at: CGPoint(x: 250, y: 140)) // grab 238,128
        bottomEditor.drag(to: finger)
        let bottomLanding = bottomEditor.landing(laneCount: 2)

        // Fingertip is identical, ghost centers are ~236pt apart — landings
        // must diverge if the center is used.
        XCTAssertNotEqual(topLanding, bottomLanding)
    }

    func testSameGhostCenterLandsSameDespiteDifferentGrabs() {
        // Different grabs but fingers chosen so ghosts overlap — landing same.
        let zones = twoLanes
        guard let aZone = zones.first(where: { $0.id == a }) else { return XCTFail() }

        // Ghost visual center — accounts for 1.04× scale around center.
        let wantedCenter = CGPoint(x: 132, y: 120)
        // visualCenter = finger - grab*scale + size*scale/2  →  finger = visualCenter + grab*scale - size*scale/2
        let scale: CGFloat = 1.04
        let topGrab = CGSize(width: 5, height: 5)
        let bottomGrab = CGSize(width: 235, height: 127)
        let size = aZone.frame.size // 240x132
        let topFinger = CGPoint(x: wantedCenter.x + topGrab.width * scale - size.width * scale / 2,
                                y: wantedCenter.y + topGrab.height * scale - size.height * scale / 2)
        let bottomFinger = CGPoint(x: wantedCenter.x + bottomGrab.width * scale - size.width * scale / 2,
                                   y: wantedCenter.y + bottomGrab.height * scale - size.height * scale / 2)

        let topEditor = editor(zones: zones)
        topEditor.startEditing()
        topEditor.lift(a, at: CGPoint(x: aZone.frame.minX + topGrab.width, y: aZone.frame.minY + topGrab.height))
        topEditor.drag(to: topFinger)

        let bottomEditor = editor(zones: zones)
        bottomEditor.startEditing()
        bottomEditor.lift(a, at: CGPoint(x: aZone.frame.minX + bottomGrab.width, y: aZone.frame.minY + bottomGrab.height))
        bottomEditor.drag(to: bottomFinger)

        XCTAssertEqual(topEditor.landing(laneCount: 2), bottomEditor.landing(laneCount: 2))
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
