// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI
import XCTest
@testable import CCPUI

/// The shell draws what the span says: a widened card widens its lane, a
/// tallened one raises its floor, and an app screen keeps its own dimensions.
@MainActor
final class LaneSlotSizingTests: XCTestCase {
    private func slots(_ placements: [Placement]) -> [LaneSlot] {
        let registry = WidgetRegistry()
        registry.register(SizingStubWidget.self)
        registry.register(SizingScreenWidget.self)
        return registry.resolve(PanelLayout([placements]))[0]
    }

    func testALaneIsAsWideAsItsWidestMember() {
        let lane = slots([
            Placement(id: SizingStubWidget.descriptor.id),
            Placement(id: SizingStubWidget.descriptor.id, span: WidgetSpan(width: 2, height: 1)),
        ])

        // Two units plus the shell's gutter between the columns — a 1x card
        // is one lane unit wherever it sits, and the lane carries the 12pt.
        XCTAssertEqual(lane.width, Layout.laneWidth * 2 + Space.oneHalf)
        XCTAssertEqual(lane.width, Layout.gridWidth(units: 2))
    }

    func testAUnitLaneIsOneUnitWide() {
        XCTAssertEqual(slots([Placement(id: SizingStubWidget.descriptor.id)]).width, Layout.laneWidth)
    }

    func testHeightSpanMultipliesTheBaseHeight() {
        let lane = slots([Placement(
            id: SizingStubWidget.descriptor.id,
            span: WidgetSpan(width: 1, height: 2)
        )])

        XCTAssertEqual(lane[0].height, WidgetSize.regular.height * 2)
    }

    func testAScreenKeepsItsOwnSizeAtAnySpan() {
        let lane = slots([Placement(
            id: SizingScreenWidget.descriptor.id,
            span: WidgetSpan(width: 3, height: 3)
        )])

        XCTAssertEqual(lane[0].width, Layout.screenWidth)
        XCTAssertEqual(lane[0].height, WidgetSize.screen.height)
        XCTAssertEqual(lane.width, Layout.screenWidth)
    }

    func testAnUnavailableSlotTakesTheSmallestCard() {
        let lane = slots([Placement(id: "widget-from-a-newer-build")])

        XCTAssertEqual(lane[0].height, WidgetSize.compact.height)
        XCTAssertEqual(lane.width, Layout.laneWidth)
    }

    func testAGridUnitIsOneLaneAndGuttersSitBetween() {
        XCTAssertEqual(Layout.gridWidth(units: 1), Layout.laneWidth)
        XCTAssertEqual(Layout.gridWidth(units: 2), Layout.laneWidth * 2 + Space.oneHalf)
        XCTAssertEqual(Layout.gridWidth(units: 3), Layout.laneWidth * 3 + Space.oneHalf * 2)
    }

    func testGridUnitsCountsTheWidestCountableSpan() {
        XCTAssertEqual(
            slots([
                Placement(id: SizingStubWidget.descriptor.id),
                Placement(id: SizingStubWidget.descriptor.id, span: WidgetSpan(width: 2, height: 1)),
            ]).gridUnits,
            2
        )
        XCTAssertEqual(slots([Placement(id: SizingScreenWidget.descriptor.id)]).gridUnits, 1)
    }

    func testAScreenBesideWidenedCardsTakesTheWider() {
        // A 2-wide grid (612) outgrows the screen's own 432.
        let lane = slots([
            Placement(id: SizingScreenWidget.descriptor.id),
            Placement(id: SizingStubWidget.descriptor.id, span: WidgetSpan(width: 2, height: 1)),
        ])

        XCTAssertEqual(lane.width, Layout.gridWidth(units: 2))
    }
}

@MainActor
private final class SizingStubWidget: CCPWidget {
    static let descriptor = WidgetDescriptor(
        id: "sizing-stub",
        title: "Sizing Stub",
        symbolName: "circle"
    )

    func makeView() -> some View { Text(verbatim: "stub") }
}

@MainActor
private final class SizingScreenWidget: CCPWidget {
    static let descriptor = WidgetDescriptor(
        id: "sizing-screen",
        title: "Sizing Screen",
        symbolName: "rectangle",
        size: .screen
    )

    func makeView() -> some View { Text(verbatim: "screen") }
}
