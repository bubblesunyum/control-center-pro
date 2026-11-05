// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPUI

/// The mail lane takes the width the display leaves it: the 432 floor on a
/// narrow screen, the leftover beside its neighbours on a wide one, and never
/// past 540 no matter how wide the glass gets.
@MainActor
final class MailLaneGrowthTests: XCTestCase {
    private func usable(_ display: CGFloat) -> CGFloat {
        display - Layout.panelInset * 2 - Space.oneHalf * 2
    }

    func testScreenBoundsAre432To540() {
        XCTAssertEqual(Layout.screenWidth, 432)
        XCTAssertEqual(Layout.screenMaxWidth, 540)
    }

    func testNarrowDisplayHoldsTheFloor() {
        // 500 of display is 460 usable; minus a 300 lane and its 12pt gutter
        // leaves 148, so the lane holds its 432 floor.
        XCTAssertEqual(Layout.screenLaneWidth(beside: [Layout.laneWidth], displayWidth: 500), 432)
    }

    func testWideDisplayTakesTheLeftover() {
        let display: CGFloat = 900
        let grown = Layout.screenLaneWidth(beside: [Layout.laneWidth], displayWidth: display)
        XCTAssertEqual(grown, usable(display) - Layout.laneWidth - Space.oneHalf)
        XCTAssertGreaterThan(grown, Layout.screenWidth)
    }

    func testVeryWideDisplayCapsAtTheCeiling() {
        XCTAssertEqual(Layout.screenLaneWidth(beside: [Layout.laneWidth], displayWidth: 2000), 540)
    }

    func testNoNeighboursOnAWideDisplayCapsToo() {
        XCTAssertEqual(Layout.screenLaneWidth(beside: [], displayWidth: 1200), 540)
    }

    func testGrownLaneStillFitsBesideItsNeighbour() {
        let display: CGFloat = 900
        let grown = Layout.screenLaneWidth(beside: [Layout.laneWidth], displayWidth: display)
        XCTAssertTrue(Layout.fits(widths: [grown, Layout.laneWidth], inWidth: display))
    }
}
