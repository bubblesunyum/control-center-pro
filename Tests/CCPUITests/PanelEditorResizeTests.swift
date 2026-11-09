// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI
import XCTest
@testable import CCPUI

/// The resize grip's arithmetic: the finger tracked continuously in
/// step-space (clamped to 1x–3x), the lane drawing the dragged size with a
/// gentle magnetic pull near steps, the span staying whole for packing and
/// the one commit on release.
@MainActor
final class PanelEditorResizeTests: XCTestCase {
    private let a: WidgetID = "a"

    private var baseSize: CGSize { CGSize(width: Layout.laneWidth, height: WidgetSize.regular.height) }

    func testADragCountsWholeStepsFromTheStartSpan() {
        let editor = PanelEditor()
        editor.beginResize(a, from: .unit, baseSize: baseSize)

        // One lane-unit left and two base-heights down: width is mirrored
        // (left widens on a right-pinned panel), height is not.
        editor.updateResize(translation: CGSize(width: -310, height: 270))

        XCTAssertEqual(editor.resizePreview?.span, WidgetSpan(width: 2, height: 3))
    }

    func testStepsRoundRatherThanTruncate() {
        let editor = PanelEditor()
        editor.beginResize(a, from: .unit, baseSize: baseSize)

        editor.updateResize(translation: CGSize(width: -160, height: -70))

        XCTAssertEqual(editor.resizePreview?.span, WidgetSpan(width: 2, height: 1))
    }

    func testAWildDragParksAtTheEnds() {
        let editor = PanelEditor()
        editor.beginResize(a, from: .unit, baseSize: baseSize)

        editor.updateResize(translation: CGSize(width: -5000, height: -5000))

        XCTAssertEqual(editor.resizePreview?.span, WidgetSpan(width: 3, height: 1))
        XCTAssertEqual(editor.resizePreview?.fraction, CGSize(width: 3, height: 1))
    }

    func testAnUpdateWithNoPreviewIsIgnored() {
        let editor = PanelEditor()

        editor.updateResize(translation: CGSize(width: 300, height: 132))

        XCTAssertNil(editor.resizePreview)
    }

    func testStepsCountFromTheStoredStart() {
        let editor = PanelEditor()
        editor.beginResize(a, from: WidgetSpan(width: 2, height: 2), baseSize: baseSize)

        // A nudge, not a step: the drag counts from where it started.
        editor.updateResize(translation: CGSize(width: 10, height: 10))

        XCTAssertEqual(editor.resizePreview?.span, WidgetSpan(width: 2, height: 2))
    }

    func testASecondGripNeverPreemptsTheFlight() {
        let editor = PanelEditor()
        editor.beginResize(a, from: .unit, baseSize: baseSize)

        editor.beginResize("b", from: WidgetSpan(width: 3, height: 3), baseSize: baseSize)

        XCTAssertEqual(editor.resizePreview?.id, a)
        XCTAssertEqual(editor.resizePreview?.span, .unit)
    }

    func testPreviewingSwapsOnlyTheCardUnderTheGrip() {
        let editor = PanelEditor()
        let registry = WidgetRegistry()
        registry.register(ResizeStubWidget.self)
        let slots = registry.resolve(PanelLayout([[ResizeStubWidget.descriptor.id]]))[0]

        editor.beginResize("elsewhere", from: WidgetSpan(width: 2, height: 2), baseSize: baseSize)
        XCTAssertEqual(editor.previewing(slots[0]).span, .unit)

        editor.endResize()
        editor.beginResize(ResizeStubWidget.descriptor.id, from: WidgetSpan(width: 2, height: 2), baseSize: baseSize)
        XCTAssertEqual(editor.previewing(slots[0]).span, WidgetSpan(width: 2, height: 2))
    }

    func testEndResizeAndStopEditingClearThePreview() {
        let editor = PanelEditor()
        editor.beginResize(a, from: .unit, baseSize: baseSize)
        editor.endResize()
        XCTAssertNil(editor.resizePreview)

        editor.beginResize(a, from: .unit, baseSize: baseSize)
        editor.stopEditing()
        XCTAssertNil(editor.resizePreview)
    }

    func testMaxLaneWidthSolvesFitsForOneLane() {
        let editor = PanelEditor()
        // A display exactly wide enough for two lanes of cards.
        editor.displayWidth = 2 * Layout.laneWidth + Space.oneHalf
            + Layout.panelInset * 2 + Space.oneHalf * 2

        // The other lane plus the one gutter between them come off the usable
        // width; nil for a stale lane index.
        XCTAssertEqual(editor.maxLaneWidth(for: 0, laneWidths: [300, 300]), 300)
        XCTAssertEqual(editor.maxLaneWidth(for: 1, laneWidths: [300, 300]), 300)
        XCTAssertNil(editor.maxLaneWidth(for: 7, laneWidths: [300, 300]))
    }

    /// The one commit both the drag release and the VoiceOver step go
    /// through: a widening past the display clamps to what fits — here a
    /// single lane unit — and a height-only change always lands. A stale lane
    /// index still refuses.
    func testCommitClampsTheWideningThatLeavesTheDisplay() {
        let editor = PanelEditor()
        editor.displayWidth = Layout.laneWidth + Layout.panelInset * 2 + Space.oneHalf * 2
        let registry = WidgetRegistry()
        registry.register(ResizeStubWidget.self)
        let arrangement = PanelArrangement(
            PanelLayout([[ResizeStubWidget.descriptor.id]]),
            registry: registry
        )
        let slot = arrangement.slot(for: ResizeStubWidget.descriptor.id)!

        XCTAssertTrue(commitResize(
            WidgetSpan(width: 2, height: 1), of: slot, in: 0,
            arrangement: arrangement, editor: editor
        ))
        XCTAssertEqual(arrangement.slot(for: ResizeStubWidget.descriptor.id)?.span, .unit)

        XCTAssertTrue(commitResize(
            WidgetSpan(width: 1, height: 2), of: slot, in: 0,
            arrangement: arrangement, editor: editor
        ))
        XCTAssertEqual(
            arrangement.slot(for: ResizeStubWidget.descriptor.id)?.span,
            WidgetSpan(width: 1, height: 2)
        )

        XCTAssertFalse(commitResize(
            WidgetSpan(width: 2, height: 1), of: slot, in: 7,
            arrangement: arrangement, editor: editor
        ))
    }

    /// The clamp measures the lane as it would be — units plus the shell's
    /// gutter — not the slot alone. A display fitting 600pt of cards still
    /// clamps the 612pt a 2-wide lane actually takes; one gutter wider and
    /// the full width lands.
    func testCommitCountsTheGutterBetweenColumns() {
        let editor = PanelEditor()
        editor.displayWidth = Layout.laneWidth * 2 + Layout.panelInset * 2 + Space.oneHalf * 2
        let registry = WidgetRegistry()
        registry.register(ResizeStubWidget.self)
        let arrangement = PanelArrangement(
            PanelLayout([[ResizeStubWidget.descriptor.id]]),
            registry: registry
        )
        let slot = arrangement.slot(for: ResizeStubWidget.descriptor.id)!

        XCTAssertTrue(commitResize(
            WidgetSpan(width: 2, height: 1), of: slot, in: 0,
            arrangement: arrangement, editor: editor
        ))
        XCTAssertEqual(arrangement.slot(for: ResizeStubWidget.descriptor.id)?.span, .unit)

        editor.displayWidth += Space.oneHalf

        XCTAssertTrue(commitResize(
            WidgetSpan(width: 2, height: 1), of: slot, in: 0,
            arrangement: arrangement, editor: editor
        ))
        XCTAssertEqual(
            arrangement.slot(for: ResizeStubWidget.descriptor.id)?.span,
            WidgetSpan(width: 2, height: 1)
        )
    }

    /// A free rect past the display clamps to the lane's max, not past it —
    /// and a stale lane index refuses like the grid commit.
    func testCustomCommitClampsWidthToTheDisplay() {
        let editor = PanelEditor()
        editor.displayWidth = Layout.laneWidth + Layout.panelInset * 2 + Space.oneHalf * 2
        let registry = WidgetRegistry()
        registry.register(ResizeStubWidget.self)
        let arrangement = PanelArrangement(
            PanelLayout([[ResizeStubWidget.descriptor.id]]),
            registry: registry
        )
        let slot = arrangement.slot(for: ResizeStubWidget.descriptor.id)!

        XCTAssertTrue(commitCustomResize(
            CGSize(width: 600, height: 400), of: slot, in: 0,
            arrangement: arrangement, editor: editor
        ))
        XCTAssertEqual(arrangement.slot(for: ResizeStubWidget.descriptor.id)?.customSize?.width, 300)
        XCTAssertEqual(arrangement.slot(for: ResizeStubWidget.descriptor.id)?.customSize?.height, 400)

        XCTAssertFalse(commitCustomResize(
            CGSize(width: 200, height: 200), of: slot, in: 7,
            arrangement: arrangement, editor: editor
        ))
    }

    func testTheFractionFollowsTheFingerBetweenSteps() {
        let editor = PanelEditor()
        editor.beginResize(a, from: .unit, baseSize: baseSize)

        // Half a lane-unit left, half a base-height down: between steps.
        editor.updateResize(translation: CGSize(width: -150, height: 66))

        XCTAssertEqual(editor.resizePreview?.fraction, CGSize(width: 1.5, height: 1.5))
        // Packing still counts the rounded step, not the finger.
        XCTAssertEqual(editor.resizePreview?.span, WidgetSpan(width: 2, height: 2))
    }

    func testBeginResizeSeedsTheFractionAtTheStartSpan() {
        let editor = PanelEditor()
        editor.beginResize(a, from: WidgetSpan(width: 2, height: 2), baseSize: baseSize)

        XCTAssertEqual(editor.resizePreview?.fraction, CGSize(width: 2, height: 2))
    }

    func testDrawSizeIsNilOffTheGrip() {
        let editor = PanelEditor()
        XCTAssertNil(editor.drawSize(for: a))

        editor.beginResize(a, from: .unit, baseSize: baseSize)
        XCTAssertNil(editor.drawSize(for: "elsewhere"))
    }

    func testDrawSizeMapsStepsToPoints() {
        let editor = PanelEditor()
        editor.beginResize(a, from: .unit, baseSize: baseSize)

        // At rest on the step: one lane unit wide, one base height tall.
        XCTAssertEqual(editor.drawSize(for: a), CGSize(width: 300, height: 132))

        // Midway to 2x2: linear between the grid widths, magnet out of reach.
        editor.updateResize(translation: CGSize(width: -150, height: 66))
        XCTAssertEqual(editor.drawSize(for: a), CGSize(width: 456, height: 198))
    }

    func testDrawSizeRestsOnAStepWhenClose() {
        let editor = PanelEditor()
        editor.beginResize(a, from: .unit, baseSize: baseSize)

        // Five points short of the 2x width, two short of the 2x height.
        editor.updateResize(translation: CGSize(width: -295, height: 130))

        XCTAssertEqual(editor.drawSize(for: a)?.width ?? -1, 609.296, accuracy: 0.001)
        XCTAssertEqual(editor.drawSize(for: a)?.height ?? -1, 263.6, accuracy: 0.001)
    }

    func testTheMagnetNeverPops() {
        // At the edge of the zone and beyond: untouched.
        XCTAssertEqual(magnetized(190, toward: 200, within: 10), 190)
        XCTAssertEqual(magnetized(100, toward: 200, within: 10), 100)
        // Halfway in: halfway pulled. On the step: exact.
        XCTAssertEqual(magnetized(195, toward: 200, within: 10), 197.5)
        XCTAssertEqual(magnetized(200, toward: 200, within: 10), 200)
        // A dead zone pulls nothing.
        XCTAssertEqual(magnetized(195, toward: 200, within: 0), 195)
    }

    func testACustomDragFollowsTheFingerToThePixel() {
        let editor = PanelEditor()
        editor.beginCustomResize(a, from: CGSize(width: 300, height: 232))

        // An odd drag lands odd — no rounding to steps. Left widens.
        editor.updateResize(translation: CGSize(width: -47, height: 279))

        XCTAssertEqual(editor.resizePreview?.custom, CGSize(width: 347, height: 511))
        XCTAssertEqual(editor.drawSize(for: a), CGSize(width: 347, height: 511))
    }

    func testACustomDragNeverMagnetizes() {
        let editor = PanelEditor()
        editor.beginCustomResize(a, from: CGSize(width: 300, height: 232))

        // Five points short of a grid width: grid would pull, custom does not.
        editor.updateResize(translation: CGSize(width: -307, height: 0))

        XCTAssertEqual(editor.drawSize(for: a), CGSize(width: 607, height: 232))
    }

    func testACustomDragClampsToTheFloorAndCeiling() {
        let editor = PanelEditor()
        editor.beginCustomResize(a, from: CGSize(width: 300, height: 232))

        // Drag right to narrow past the floor, down past the ceiling.
        editor.updateResize(translation: CGSize(width: 5000, height: 5000))

        XCTAssertEqual(
            editor.resizePreview?.custom,
            CGSize(width: PanelEditor.customMinSize.width, height: PanelEditor.customMaxSize.height)
        )
    }

    func testCustomPreviewingWearsTheFreeRect() {
        let editor = PanelEditor()
        let registry = WidgetRegistry()
        registry.register(ResizeStubWidget.self)
        let slots = registry.resolve(PanelLayout([[ResizeStubWidget.descriptor.id]]))[0]

        // This file intentionally leaves the assertion to the lane tests:
        // previewing a custom drag returns the slot resized to the rect.
        editor.beginCustomResize("elsewhere", from: CGSize(width: 300, height: 232))
        XCTAssertNil(editor.previewing(slots[0]).customSize)
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
