// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPUI

/// The panel's width math, measured against real lane widths — the refusal
/// rule behind new lanes and, now, widened ones.
final class PanelWidthTests: XCTestCase {
    /// A 1440 display holds 1400 of lanes and the gaps between them.
    private let display: CGFloat = 1440

    func testAnEmptyPanelFits() {
        XCTAssertTrue(Layout.fits(widths: [], inWidth: display))
    }

    func testLanesAndTheirGapsMustFit() {
        XCTAssertTrue(Layout.fits(widths: [300, 300], inWidth: display))
        XCTAssertFalse(Layout.fits(widths: [1400, 300], inWidth: display))
    }

    func testTheBoundaryIsExact() {
        // 300 + 12 + 300 = 612 of lanes and gaps on 652 of display.
        XCTAssertTrue(Layout.fits(widths: [300, 300], inWidth: 652))
        XCTAssertFalse(Layout.fits(widths: [300, 300], inWidth: 651))
    }

    func testAWidenedLaneCountsAtItsNewWidth() {
        XCTAssertTrue(Layout.fits(widths: [600], inWidth: display))
        XCTAssertFalse(Layout.fits(widths: [600, 600, 300], inWidth: 1300))
    }

    func testAnotherLaneStillMeansADefaultOne() {
        XCTAssertTrue(Layout.fitsAnotherLane(beside: [300], inWidth: display))
        XCTAssertFalse(Layout.fitsAnotherLane(beside: [1400], inWidth: display))
        XCTAssertTrue(Layout.fitsAnotherLane(beside: [], inWidth: 0))
    }
}
