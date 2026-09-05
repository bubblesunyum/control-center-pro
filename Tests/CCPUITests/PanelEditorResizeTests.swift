// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI
import XCTest
@testable import CCPUI

/// The resize grip's arithmetic: whole steps of the base size, clamped to
/// 1x–3x, previewed in the editor and committed once on release.
@MainActor
final class PanelEditorResizeTests: XCTestCase {
    private let a: WidgetID = "a"

    private var baseSize: CGSize { CGSize(width: Layout.laneWidth, height: WidgetSize.regular.height) }

    func testADragCountsWholeStepsFromTheStartSpan() {
        let editor = PanelEditor()
        editor.beginResize(a, from: .unit)

        // One lane-unit right and two base-heights down.
        editor.updateResize(
            translation: CGSize(width: 310, height: 270),
            from: .unit,
            baseSize: baseSize
        )

        XCTAssertEqual(editor.resizePreview?.span, WidgetSpan(width: 2, height: 3))
    }

    func testStepsRoundRatherThanTruncate() {
        let editor = PanelEditor()
        editor.beginResize(a, from: .unit)

        editor.updateResize(translation: CGSize(width: 160, height: -70), from: .unit, baseSize: baseSize)

        XCTAssertEqual(editor.resizePreview?.span, WidgetSpan(width: 2, height: 1))
    }

    func testAWildDragParksAtTheEnds() {
        let editor = PanelEditor()
        editor.beginResize(a, from: .unit)

        editor.updateResize(translation: CGSize(width: 5000, height: -5000), from: .unit, baseSize: baseSize)

        XCTAssertEqual(editor.resizePreview?.span, WidgetSpan(width: 3, height: 1))
    }

    func testAnUpdateWithNoPreviewIsIgnored() {
        let editor = PanelEditor()

        editor.updateResize(translation: CGSize(width: 300, height: 132), from: .unit, baseSize: baseSize)

        XCTAssertNil(editor.resizePreview)
    }

    func testASecondGripNeverPreemptsTheFlight() {
        let editor = PanelEditor()
        editor.beginResize(a, from: .unit)

        editor.beginResize("b", from: WidgetSpan(width: 3, height: 3))

        XCTAssertEqual(editor.resizePreview?.id, a)
        XCTAssertEqual(editor.resizePreview?.span, .unit)
    }

    func testPreviewingSwapsOnlyTheCardUnderTheGrip() {
        let editor = PanelEditor()
        let registry = WidgetRegistry()
        registry.register(ResizeStubWidget.self)
        let slots = registry.resolve(PanelLayout([[ResizeStubWidget.descriptor.id]]))[0]

        editor.beginResize("elsewhere", from: WidgetSpan(width: 2, height: 2))
        XCTAssertEqual(editor.previewing(slots[0]).span, .unit)

        editor.endResize()
        editor.beginResize(ResizeStubWidget.descriptor.id, from: WidgetSpan(width: 2, height: 2))
        XCTAssertEqual(editor.previewing(slots[0]).span, WidgetSpan(width: 2, height: 2))
    }

    func testEndResizeAndStopEditingClearThePreview() {
        let editor = PanelEditor()
        editor.beginResize(a, from: .unit)
        editor.endResize()
        XCTAssertNil(editor.resizePreview)

        editor.beginResize(a, from: .unit)
        editor.stopEditing()
        XCTAssertNil(editor.resizePreview)
    }

    func testAWideningThatFitsIsAllowedAndOneThatDoesNotIsNot() {
        let editor = PanelEditor()
        // A display exactly wide enough for two lanes of cards.
        editor.displayWidth = 2 * Layout.laneWidth + Space.oneHalf
            + Layout.panelInset * 2 + Space.oneHalf * 2

        XCTAssertTrue(editor.canResizeLane(0, to: Layout.laneWidth, laneWidths: [300, 300]))
        XCTAssertFalse(editor.canResizeLane(0, to: Layout.laneWidth * 2, laneWidths: [300, 300]))
        XCTAssertFalse(editor.canResizeLane(7, to: Layout.laneWidth, laneWidths: [300, 300]))
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
