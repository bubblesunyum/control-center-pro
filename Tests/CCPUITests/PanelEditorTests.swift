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
    private func dragging(_ id: WidgetID, to point: CGPoint, roomForLanes: Int = .max) -> PanelEditor {
        let editor = editor(zones: twoLanes)
        editor.displayWidth = Self.displayWidth(fitting: roomForLanes)
        editor.startEditing()
        if let zone = twoLanes.first(where: { $0.id == id }) {
            editor.lift(id, at: CGPoint(x: zone.frame.minX + 8, y: zone.frame.minY + 8))
        } else {
            editor.lift(id, at: CGPoint(x: 20, y: 20))
        }
        // twoLanes has 2 default-width lanes; landing needs those, not the room.
        editor.drag(to: point, laneWidths: Self.twoDefaultLanes)
        return editor
    }

    /// An editor with `id` in the air and the ghost's visual center at
    /// `center`. Inverts `Lifted.visualCenter(at:)` so tests can say where the
    /// card looks like it is rather than where the fingertip sits.
    private func draggingCentered(_ id: WidgetID, to center: CGPoint, roomForLanes: Int = .max) -> PanelEditor {
        let editor = editor(zones: twoLanes)
        editor.displayWidth = Self.displayWidth(fitting: roomForLanes)
        editor.startEditing()
        guard let zone = twoLanes.first(where: { $0.id == id }) else { return editor }
        editor.lift(id, at: CGPoint(x: zone.frame.minX + 8, y: zone.frame.minY + 8))
        editor.drag(
            to: Self.fingerFor(center: center, zone: zone),
            laneWidths: Self.twoDefaultLanes
        )
        return editor
    }

    /// The fingertip putting `zone`'s ghost center at `center` for an 8pt grab.
    private static func fingerFor(center: CGPoint, zone: PanelEditor.DropZone) -> CGPoint {
        let scale = PanelEditor.Lifted.scale
        return CGPoint(
            x: center.x + 8 * scale - zone.frame.width * scale / 2,
            y: center.y + 8 * scale - zone.frame.height * scale / 2
        )
    }

    /// The widths of the lanes `twoLanes` describes.
    private static let twoDefaultLanes = [Layout.laneWidth, Layout.laneWidth]

    /// A display exactly wide enough for `count` lanes of cards, so a test can
    /// say how much room there is in the unit the panel is actually built from.
    private static func displayWidth(fitting count: Int) -> CGFloat {
        guard count != .max else { return .greatestFiniteMagnitude }
        let lanes = CGFloat(count)
        return lanes * Layout.laneWidth + (lanes - 1) * Space.oneHalf
            + Layout.panelInset * 2 + Space.oneHalf * 2
    }

    func testALaneHoldingAnAppScreenEatsTheRoomOfMoreThanOne() {
        // Two 300pt lanes fit where two 300pt lanes fit — but swap one for a
        // 432pt screen lane and the third column no longer has anywhere to go.
        let editor = dragging(a, to: CGPoint(x: -110, y: 20), roomForLanes: 3)

        XCTAssertTrue(editor.canAddLane(beside: Self.twoDefaultLanes))
        XCTAssertFalse(editor.canAddLane(beside: [WidgetSize.screen.width, Layout.laneWidth]))
    }

    func testAboveEverythingInALaneLandsFirst() {
        // Ghost center, not fingertip, decides the index — fingertip must be
        // ~half a card above the first mid to have the ghost above it.
        let landing = dragging(c, to: CGPoint(x: 100, y: -40)).landing(laneWidths: Self.twoDefaultLanes)

        XCTAssertEqual(landing, .into(lane: 0, index: 0))
    }

    func testBelowEverythingInALaneLandsLast() {
        let landing = dragging(c, to: CGPoint(x: 100, y: 400)).landing(laneWidths: Self.twoDefaultLanes)

        XCTAssertEqual(landing, .into(lane: 0, index: 2))
    }

    /// The card in the air doesn't count itself, which is what makes dragging
    /// one down its own lane land it where the finger is rather than one short.
    func testACardDoesNotCountItsOwnPlace() {
        let landing = dragging(a, to: CGPoint(x: 100, y: 400)).landing(laneWidths: Self.twoDefaultLanes)

        XCTAssertEqual(landing, .into(lane: 0, index: 1), "b is the only card it would sit below")
    }

    func testTheLaneUnderTheFingerIsTheOneItLandsIn() {
        let landing = dragging(a, to: CGPoint(x: 300, y: 20)).landing(laneWidths: Self.twoDefaultLanes)

        XCTAssertEqual(landing, .into(lane: 1, index: 0))
    }

    /// The panel is pinned to the right of the screen and grows leftward, so
    /// the column a drag opens is the new leftmost one.
    func testLeftOfEverythingOpensANewLeadingLane() {
        // New lane triggers when ghost center is left of every card.
        let landing = dragging(a, to: CGPoint(x: -110, y: 20), roomForLanes: 4).landing(laneWidths: Self.twoDefaultLanes)

        XCTAssertEqual(landing, .newLane(at: 0))
    }

    /// The gutter between two lanes opens a lane between them. twoLanes holds
    /// a at 12..252 and c at 264.., so 258 is the middle of the 12pt gutter.
    func testBetweenLanesOpensANewMiddleLane() {
        let editor = draggingCentered(a, to: CGPoint(x: 258, y: 60), roomForLanes: 4)

        XCTAssertEqual(editor.landing(laneWidths: Self.twoDefaultLanes), .newLane(at: 1))
        XCTAssertNotNil(editor.offeredNewLaneAt(beside: Self.twoDefaultLanes))
    }

    /// Right of everything opens a lane past the end.
    func testRightOfEverythingOpensANewTrailingLane() {
        let editor = draggingCentered(a, to: CGPoint(x: 560, y: 60), roomForLanes: 4)

        XCTAssertEqual(editor.landing(laneWidths: Self.twoDefaultLanes), .newLane(at: 2))
        XCTAssertNotNil(editor.offeredNewLaneAt(beside: Self.twoDefaultLanes))
    }

    /// A card alone in its lane has no adjacent gap to open: the commit would
    /// collapse straight back, so no lane is offered there. c sits alone in
    /// lane 1 — the middle gutter and the trailing edge are its neighbours.
    func testGapsAdjacentToASoleOccupantOfferNothing() {
        let middle = draggingCentered(c, to: CGPoint(x: 258, y: 60), roomForLanes: 4)
        XCTAssertNil(middle.landing(laneWidths: Self.twoDefaultLanes))
        XCTAssertNil(middle.offeredNewLaneAt(beside: Self.twoDefaultLanes))

        let trailing = draggingCentered(c, to: CGPoint(x: 560, y: 60), roomForLanes: 4)
        XCTAssertNil(trailing.landing(laneWidths: Self.twoDefaultLanes))
        XCTAssertNil(trailing.offeredNewLaneAt(beside: Self.twoDefaultLanes))
    }

    /// The far gap from a sole occupant is a real move and still offered.
    func testFarGapFromASoleOccupantStillOpens() {
        let leading = draggingCentered(c, to: CGPoint(x: -100, y: 60), roomForLanes: 4)

        XCTAssertEqual(leading.landing(laneWidths: Self.twoDefaultLanes), .newLane(at: 0))
        XCTAssertNotNil(leading.offeredNewLaneAt(beside: Self.twoDefaultLanes))
    }

    /// One lane has no gap worth opening: either edge collapses back.
    func testASingleLaneOffersNoNewLane() {
        let zones = [PanelEditor.DropZone(id: a, lane: 0, frame: CGRect(x: 12, y: 12, width: 240, height: 132))]
        let widths = [Layout.laneWidth]
        func landing(at center: CGPoint) -> PanelEditor.Landing? {
            let editor = editor(zones: zones)
            editor.displayWidth = Self.displayWidth(fitting: 4)
            editor.startEditing()
            editor.lift(a, at: CGPoint(x: 20, y: 20))
            editor.drag(to: Self.fingerFor(center: center, zone: zones[0]), laneWidths: widths)
            return editor.landing(laneWidths: widths)
        }

        XCTAssertNil(landing(at: CGPoint(x: -100, y: 60)))
        XCTAssertNil(landing(at: CGPoint(x: 400, y: 60)))
    }

    /// The window grows left by one lane to preview the column; the snapshot
    /// follows per lane so later frames hit-test against what the eye sees.
    /// Trailing gap: no lane moves inside the panel, so none of the snapshot
    /// shifts — the ghost over lane 1 still lands in lane 1.
    func testSnapshotShiftAfterTrailingOffer() {
        let editor = editor(zones: twoLanes)
        editor.displayWidth = Self.displayWidth(fitting: 4)
        editor.startEditing()
        let zone = twoLanes.first(where: { $0.id == a })!
        editor.lift(a, at: CGPoint(x: zone.frame.minX + 8, y: zone.frame.minY + 8))
        editor.drag(to: Self.fingerFor(center: CGPoint(x: 560, y: 60), zone: zone), laneWidths: Self.twoDefaultLanes)
        XCTAssertEqual(editor.previewLanding, .newLane(at: 2))

        editor.shiftSnapshot(dx: Layout.laneWidth + Space.oneHalf, newLaneAt: 2)
        editor.drag(to: Self.fingerFor(center: CGPoint(x: 384, y: 60), zone: zone), laneWidths: Self.twoDefaultLanes)

        XCTAssertEqual(editor.landing(laneWidths: Self.twoDefaultLanes), .into(lane: 1, index: 0))
    }

    /// Middle gap: only the lanes right of the opening shift.
    func testSnapshotShiftAfterMiddleOffer() {
        let editor = editor(zones: twoLanes)
        editor.displayWidth = Self.displayWidth(fitting: 4)
        editor.startEditing()
        let zone = twoLanes.first(where: { $0.id == a })!
        editor.lift(a, at: CGPoint(x: zone.frame.minX + 8, y: zone.frame.minY + 8))
        editor.drag(to: Self.fingerFor(center: CGPoint(x: 258, y: 60), zone: zone), laneWidths: Self.twoDefaultLanes)
        XCTAssertEqual(editor.previewLanding, .newLane(at: 1))

        editor.shiftSnapshot(dx: Layout.laneWidth + Space.oneHalf, newLaneAt: 1)
        editor.drag(to: Self.fingerFor(center: CGPoint(x: 132, y: 60), zone: zone), laneWidths: Self.twoDefaultLanes)

        XCTAssertEqual(editor.landing(laneWidths: Self.twoDefaultLanes), .into(lane: 0, index: 0))
    }

    /// ccp-p6g: the panel is anchored top-right and doesn't scroll, so a lane
    /// the display can't show is one the user would lose things in.
    func testNoNewLaneWhenTheDisplayIsFull() {
        let leading = dragging(a, to: CGPoint(x: -110, y: 20), roomForLanes: 2)
        XCTAssertNil(leading.landing(laneWidths: Self.twoDefaultLanes))
        XCTAssertNil(leading.offeredNewLaneAt(beside: Self.twoDefaultLanes))

        let middle = draggingCentered(a, to: CGPoint(x: 258, y: 60), roomForLanes: 2)
        XCTAssertNil(middle.landing(laneWidths: Self.twoDefaultLanes))
        XCTAssertNil(middle.offeredNewLaneAt(beside: Self.twoDefaultLanes))

        let trailing = draggingCentered(a, to: CGPoint(x: 560, y: 60), roomForLanes: 2)
        XCTAssertNil(trailing.landing(laneWidths: Self.twoDefaultLanes))
        XCTAssertNil(trailing.offeredNewLaneAt(beside: Self.twoDefaultLanes))
    }

    func testTheNewLaneIsOfferedOnlyWhenHoveringAGapOrEdge() {
        // New lane no longer offered for whole drag — that shifted the grid
        // at lift even before the finger went left. Now it appears only when
        // the ghost hovers a gap between lanes or an outer edge.
        let notHovering = dragging(a, to: CGPoint(x: 300, y: 20), roomForLanes: 4)
        XCTAssertNil(notHovering.offeredNewLaneAt(beside: Self.twoDefaultLanes))

        let hoveringLeading = dragging(a, to: CGPoint(x: -110, y: 20), roomForLanes: 4)
        XCTAssertNotNil(hoveringLeading.offeredNewLaneAt(beside: Self.twoDefaultLanes))

        let hoveringMiddle = draggingCentered(a, to: CGPoint(x: 258, y: 60), roomForLanes: 4)
        XCTAssertNotNil(hoveringMiddle.offeredNewLaneAt(beside: Self.twoDefaultLanes))

        let hoveringTrailing = draggingCentered(a, to: CGPoint(x: 560, y: 60), roomForLanes: 4)
        XCTAssertNotNil(hoveringTrailing.offeredNewLaneAt(beside: Self.twoDefaultLanes))
    }

    func testNothingIsOfferedWhenNothingIsInTheAir() {
        XCTAssertNil(editor(zones: twoLanes).offeredNewLaneAt(beside: Self.twoDefaultLanes))
    }

    func testALandingNeedsSomethingInTheAir() {
        XCTAssertNil(editor(zones: twoLanes).landing(laneWidths: Self.twoDefaultLanes))
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
        let topLanding = topEditor.landing(laneWidths: Self.twoDefaultLanes)

        // Grab near bottom-right of `a`
        let bottomEditor = editor(zones: twoLanes)
        bottomEditor.startEditing()
        bottomEditor.lift(a, at: CGPoint(x: 250, y: 140)) // grab 238,128
        bottomEditor.drag(to: finger)
        let bottomLanding = bottomEditor.landing(laneWidths: Self.twoDefaultLanes)

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

        XCTAssertEqual(topEditor.landing(laneWidths: Self.twoDefaultLanes), bottomEditor.landing(laneWidths: Self.twoDefaultLanes))
    }

    // MARK: - Rows sharing a lane

    /// Lane 0 is two units wide: a and b side by side, c full-width below.
    private var pairedRow: [PanelEditor.DropZone] {
        [
            .init(id: a, lane: 0, frame: CGRect(x: 12, y: 12, width: 294, height: 132)),
            .init(id: b, lane: 0, frame: CGRect(x: 318, y: 12, width: 294, height: 132)),
            .init(id: c, lane: 0, frame: CGRect(x: 12, y: 156, width: 600, height: 232)),
            .init(id: "d", lane: 1, frame: CGRect(x: 624, y: 12, width: 300, height: 132)),
        ]
    }

    /// An editor with d in the air and the ghost's center at `center`.
    private func draggingD(toCenter center: CGPoint) -> PanelEditor {
        let editor = editor(zones: pairedRow)
        editor.displayWidth = .greatestFiniteMagnitude
        editor.startEditing()
        let zone = pairedRow.first(where: { $0.id == "d" })!
        editor.lift("d", at: CGPoint(x: zone.frame.minX + 8, y: zone.frame.minY + 8))
        let scale = PanelEditor.Lifted.scale
        editor.drag(
            to: CGPoint(
                x: center.x + 8 * scale - zone.frame.width * scale / 2,
                y: center.y + 8 * scale - zone.frame.height * scale / 2
            ),
            laneWidths: [Layout.gridWidth(units: 2), Layout.laneWidth]
        )
        return editor
    }

    private func rowLanding(at center: CGPoint) -> PanelEditor.Landing? {
        draggingD(toCenter: center).landing(laneWidths: [Layout.gridWidth(units: 2), Layout.laneWidth])
    }

    func testLeftOfARowLandsFirst() {
        XCTAssertEqual(rowLanding(at: CGPoint(x: 100, y: 60)), .into(lane: 0, index: 0))
    }

    func testBetweenSideBySideCardsLandsBetweenThem() {
        XCTAssertEqual(rowLanding(at: CGPoint(x: 312, y: 60)), .into(lane: 0, index: 1))
    }

    func testRightOfARowLandsAfterIt() {
        XCTAssertEqual(rowLanding(at: CGPoint(x: 550, y: 60)), .into(lane: 0, index: 2))
    }

    func testBelowARowButAboveTheNextCardLandsAfterTheRow() {
        XCTAssertEqual(rowLanding(at: CGPoint(x: 300, y: 150)), .into(lane: 0, index: 2))
    }

    func testBelowEverythingInARowedLaneLandsLast() {
        XCTAssertEqual(rowLanding(at: CGPoint(x: 300, y: 500)), .into(lane: 0, index: 3))
    }

    /// A 2-wide lane with an uneven row: tall a beside short b.
    private var unevenRow: [PanelEditor.DropZone] {
        [
            .init(id: a, lane: 0, frame: CGRect(x: 12, y: 12, width: 294, height: 232)),
            .init(id: b, lane: 0, frame: CGRect(x: 318, y: 12, width: 294, height: 64)),
            .init(id: c, lane: 0, frame: CGRect(x: 12, y: 256, width: 600, height: 132)),
        ]
    }

    /// Lift `id` where it sits and release without moving: the gap stays
    /// home. The lifted card holds its row open for banding — without that,
    /// the row collapses to its mate and the midY rule seats the card in the
    /// mate's place, so a no-op gesture swaps the pair.
    private func liftAndHold(_ id: WidgetID, in zones: [PanelEditor.DropZone]) -> PanelEditor.Landing? {
        let editor = editor(zones: zones)
        editor.displayWidth = .greatestFiniteMagnitude
        editor.startEditing()
        let zone = zones.first(where: { $0.id == id })!
        let at = CGPoint(x: zone.frame.minX + 8, y: zone.frame.minY + 8)
        editor.lift(id, at: at)
        editor.drag(to: at, laneWidths: [Layout.gridWidth(units: 2)])
        return editor.landing(laneWidths: [Layout.gridWidth(units: 2)])
    }

    func testLiftingTheShortHalfOfARowKeepsItsSeat() {
        XCTAssertEqual(liftAndHold(b, in: unevenRow), .into(lane: 0, index: 1))
    }

    func testLiftingTheTallHalfOfARowKeepsItsSeat() {
        XCTAssertEqual(liftAndHold(a, in: unevenRow), .into(lane: 0, index: 0))
    }
}

@MainActor
final class LaneCapacityTests: XCTestCase {
    private let lane = Layout.laneWidth

    func testALaneAndItsGutterHaveToFit() {
        XCTAssertTrue(Layout.fitsAnotherLane(beside: [lane, lane, lane], inWidth: 1440))
        XCTAssertFalse(Layout.fitsAnotherLane(beside: [lane, lane, lane, lane], inWidth: 1440))

        XCTAssertTrue(Layout.fitsAnotherLane(beside: [lane], inWidth: 800))
        XCTAssertFalse(Layout.fitsAnotherLane(beside: [lane, lane], inWidth: 800))
    }

    /// A lane is only as wide as the widest thing in it, so a screen widget
    /// costs the panel more room than a card does — and the count of lanes
    /// says nothing about whether another fits.
    func testAScreenLaneCostsMoreRoomThanALaneOfCards() {
        let screen = WidgetSize.screen.width
        XCTAssertTrue(Layout.fitsAnotherLane(beside: [lane, lane, lane], inWidth: 1380))
        XCTAssertFalse(Layout.fitsAnotherLane(beside: [screen, lane, lane], inWidth: 1380))
    }

    /// A display too narrow for one lane still gets one: a panel with no lanes
    /// is not an improvement on a panel that is slightly too wide.
    func testEvenAnImpossiblyNarrowDisplayGetsOneLane() {
        XCTAssertTrue(Layout.fitsAnotherLane(beside: [], inWidth: 100))
        XCTAssertFalse(Layout.fitsAnotherLane(beside: [lane], inWidth: 100))
    }
}
