// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI
import XCTest
@testable import CCPUI

/// The resize grip's arithmetic: the card follows the finger point for point
/// from the size it was drawn at, held only to the display's width and the
/// grab floor, and the release stores exactly what the finger showed.
@MainActor
final class PanelEditorResizeTests: XCTestCase {
    private let a: WidgetID = "a"
    private let start = CGSize(width: 300, height: 232)

    private func editor(resizing maxWidth: CGFloat = 2000) -> PanelEditor {
        let editor = PanelEditor()
        editor.beginResize(a, from: start, maxWidth: maxWidth)
        return editor
    }

    func testTheFirstFrameIsTheCardAsGrabbed() {
        XCTAssertEqual(editor().drawSize(for: a), start)
    }

    /// The grip is on the leading corner of a right-pinned card: left widens,
    /// down grows, every point of travel one point of size.
    func testTheCardFollowsTheFingerToThePixel() {
        let editor = editor()

        editor.updateResize(translation: CGSize(width: -37.5, height: 11.25))
        XCTAssertEqual(editor.drawSize(for: a), CGSize(width: 337.5, height: 243.25))

        editor.updateResize(translation: CGSize(width: 61, height: -100))
        XCTAssertEqual(editor.drawSize(for: a), CGSize(width: 239, height: 132))
    }

    func testWidthParksAtTheRoomBesideTheOtherLanes() {
        let editor = editor(resizing: 420)

        editor.updateResize(translation: CGSize(width: -900, height: 0))
        XCTAssertEqual(editor.drawSize(for: a)?.width, 420)
    }

    func testHeightHasNoCeiling() {
        let editor = editor()

        editor.updateResize(translation: CGSize(width: 0, height: 4000))
        XCTAssertEqual(editor.drawSize(for: a)?.height, 4232)
    }

    func testOnlyTheGrabFloorStopsAShrink() {
        let editor = editor()

        editor.updateResize(translation: CGSize(width: 900, height: -900))
        XCTAssertEqual(
            editor.drawSize(for: a),
            CGSize(width: PanelEditor.minimumCardSize, height: PanelEditor.minimumCardSize)
        )
    }

    func testAnUpdateWithNoGripHeldIsIgnored() {
        let editor = PanelEditor()

        editor.updateResize(translation: CGSize(width: -50, height: 50))
        XCTAssertNil(editor.resize)
    }

    func testASecondGripNeverPreemptsTheFlight() {
        let editor = editor()

        editor.beginResize("b", from: CGSize(width: 10, height: 10), maxWidth: 2000)
        XCTAssertEqual(editor.resize?.id, a)
        XCTAssertNil(editor.drawSize(for: "b"))
    }

    func testEndResizeAndStopEditingClearTheDrag() {
        let ended = editor()
        ended.endResize()
        XCTAssertNil(ended.resize)

        let stopped = editor()
        stopped.startEditing()
        stopped.stopEditing()
        XCTAssertNil(stopped.resize)
    }

    // MARK: - Room and commit

    private func display(fitting room: CGFloat, lanes: Int) -> CGFloat {
        room + Space.oneHalf * CGFloat(lanes - 1) + Layout.panelInset * 2 + Space.oneHalf * 2
    }

    func testMaxLaneWidthIsTheRoomBesideTheOthers() {
        let editor = PanelEditor()
        editor.displayWidth = display(fitting: 1000, lanes: 2)

        XCTAssertEqual(editor.maxLaneWidth(for: 0, laneWidths: [300, 400]), 600)
        XCTAssertEqual(editor.maxLaneWidth(for: 1, laneWidths: [300, 400]), 700)
        XCTAssertNil(editor.maxLaneWidth(for: 7, laneWidths: [300, 400]))
    }

    /// A layout from a wider display draws fitted; the room is measured
    /// against the lanes as drawn, so the grabbed lane always has at least
    /// its own drawn width to start from.
    func testMaxLaneWidthMeasuresAnOverflowingLayoutAsDrawn() {
        let editor = PanelEditor()
        editor.displayWidth = display(fitting: 1000, lanes: 2)

        XCTAssertEqual(editor.maxLaneWidth(for: 0, laneWidths: [1200, 800])!, 600, accuracy: 0.001)
    }

    private func arrangement(_ layout: PanelLayout) -> PanelArrangement {
        let registry = WidgetRegistry()
        registry.register(ResizeStubWidget.self)
        return PanelArrangement(layout, registry: registry)
    }

    func testTheReleaseStoresExactlyTheDraggedSize() {
        let editor = PanelEditor()
        editor.displayWidth = 1800
        let id = ResizeStubWidget.descriptor.id
        let arrangement = arrangement(PanelLayout([[id]]))

        XCTAssertTrue(commitResize(CGSize(width: 333.25, height: 87.5), of: id, arrangement: arrangement, editor: editor))
        XCTAssertEqual(arrangement.slot(for: id)?.customSize, CustomWidgetSize(width: 333.25, height: 87.5))
    }

    func testTheCommitClampsLikeTheDrag() {
        let editor = PanelEditor()
        editor.displayWidth = display(fitting: 500, lanes: 1)
        let id = ResizeStubWidget.descriptor.id
        let arrangement = arrangement(PanelLayout([[id]]))

        commitResize(CGSize(width: 9000, height: 1), of: id, arrangement: arrangement, editor: editor)
        XCTAssertEqual(
            arrangement.slot(for: id)?.customSize,
            CustomWidgetSize(width: 500, height: Double(PanelEditor.minimumCardSize))
        )
    }

    func testACardNoLongerPlacedRefuses() {
        let editor = PanelEditor()
        let arrangement = arrangement(PanelLayout([[ResizeStubWidget.descriptor.id]]))

        XCTAssertFalse(commitResize(CGSize(width: 300, height: 300), of: "gone", arrangement: arrangement, editor: editor))
    }
}

@MainActor
private final class ResizeStubWidget: CCPWidget {
    static let descriptor = WidgetDescriptor(
        id: "resize-stub",
        title: "Resize Stub",
        symbolName: "circle"
    )

    func makeView() -> some View { Text(verbatim: "stub") }
}
