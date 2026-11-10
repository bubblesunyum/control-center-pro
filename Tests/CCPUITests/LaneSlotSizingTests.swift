// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI
import XCTest
@testable import CCPUI

/// What a card and its lane measure: a resized card is the size it was
/// dragged to, an untouched one its widget's default, a lane its widest
/// card — and the lanes together never more than the display.
@MainActor
final class LaneSlotSizingTests: XCTestCase {
    private let stub = SizingStubWidget.descriptor.id
    private let screen = SizingScreenWidget.descriptor.id

    private func slots(_ placements: [Placement]) -> [LaneSlot] {
        let registry = WidgetRegistry()
        registry.register(SizingStubWidget.self)
        registry.register(SizingScreenWidget.self)
        return registry.resolve(PanelLayout([placements]))[0]
    }

    private func sized(_ width: Double, _ height: Double) -> CustomWidgetSize {
        CustomWidgetSize(width: width, height: height)
    }

    func testAnUntouchedCardHasNoStoredSizeAndItsDefaultWidth() {
        let lane = slots([Placement(id: stub), Placement(id: screen)])

        XCTAssertNil(lane[0].storedSize)
        XCTAssertEqual(lane[0].width, Layout.laneWidth)
        XCTAssertEqual(lane[1].width, Layout.screenWidth)
    }

    func testAResizedCardIsExactlyItsSize() {
        let lane = slots([Placement(id: stub, customSize: sized(173.5, 61))])

        XCTAssertEqual(lane[0].storedSize, CGSize(width: 173.5, height: 61))
        XCTAssertEqual(lane[0].width, 173.5)
    }

    func testTheSizeWinsOverALegacySpan() {
        let lane = slots([Placement(id: stub, span: WidgetSpan(width: 3, height: 3), customSize: sized(200, 90))])

        XCTAssertEqual(lane[0].storedSize, CGSize(width: 200, height: 90))
    }

    /// A file from before free resizing opens looking the way it was left:
    /// the points its span drew, gutter included.
    func testALegacySpanDrawsThePointsItUsedTo() {
        let lane = slots([Placement(id: stub, span: WidgetSpan(width: 2, height: 3))])

        XCTAssertEqual(lane[0].storedSize, CGSize(
            width: Layout.laneWidth * 2 + Space.oneHalf,
            height: WidgetSize.regular.height * 3
        ))
    }

    func testAScreenIgnoresALegacySpan() {
        XCTAssertNil(slots([Placement(id: screen, span: WidgetSpan(width: 2, height: 2))])[0].storedSize)
    }

    func testALaneIsAsWideAsItsWidestCard() {
        let narrow = slots([Placement(id: stub, customSize: sized(120, 80)), Placement(id: screen)])
        let wide = slots([Placement(id: stub, customSize: sized(640, 80)), Placement(id: screen)])

        XCTAssertEqual(narrow.width, Layout.screenWidth)
        XCTAssertEqual(wide.width, 640)
    }

    func testALaneOfOneNarrowCardIsThatNarrow() {
        XCTAssertEqual(slots([Placement(id: stub, customSize: sized(90, 80))]).width, 90)
    }

    func testAnEmptyLaneIsALaneOfCards() {
        XCTAssertEqual([LaneSlot]().width, Layout.laneWidth)
    }

    func testAnUnavailableSlotTakesTheDefaultCard() {
        let lane = slots([Placement(id: "widget-from-a-newer-build", customSize: sized(500, 500))])

        XCTAssertNil(lane[0].storedSize, "there is no widget to resize")
        XCTAssertEqual(lane[0].width, Layout.laneWidth)
    }

    // MARK: - Fitting the display

    private func display(fitting room: CGFloat, lanes: Int) -> CGFloat {
        room + Space.oneHalf * CGFloat(lanes - 1) + Layout.panelInset * 2 + Space.oneHalf * 2
    }

    func testLanesThatFitDrawAsStored() {
        let width = display(fitting: 1000, lanes: 2)

        XCTAssertEqual(Layout.fittedLaneWidths([600, 400], inWidth: width), [600, 400])
    }

    func testLanesThatOverflowShrinkInProportionToExactlyTheRoom() {
        let width = display(fitting: 1000, lanes: 2)
        let fitted = Layout.fittedLaneWidths([1200, 800], inWidth: width)

        XCTAssertEqual(fitted[0], 600, accuracy: 0.001)
        XCTAssertEqual(fitted[1], 400, accuracy: 0.001)
        XCTAssertTrue(Layout.fits(widths: fitted, inWidth: width))
    }

    func testAlwaysAMarginOnBothSides() {
        let width: CGFloat = 1800
        let fitted = Layout.fittedLaneWidths([5000], inWidth: width)

        XCTAssertEqual(fitted[0], width - Layout.panelInset * 2 - Space.oneHalf * 2, accuracy: 0.001)
    }

    func testNoLanesFitNothing() {
        XCTAssertEqual(Layout.fittedLaneWidths([], inWidth: 1800), [])
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
