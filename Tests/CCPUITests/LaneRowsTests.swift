// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI
import XCTest
@testable import CCPUI

/// The lane's greedy flow: consecutive cards share a row while their spans
/// fit the grid, and anything uncountable stands alone.
@MainActor
final class LaneRowsTests: XCTestCase {
    func testAPairSharesARowOfTwo() {
        XCTAssertEqual(packRowIndexes([1, 1], columns: 2), [[0, 1]])
    }

    func testOverflowWrapsToTheNextRow() {
        XCTAssertEqual(packRowIndexes([1, 1, 1], columns: 2), [[0, 1], [2]])
    }

    func testAWideCardFillsItsRow() {
        XCTAssertEqual(packRowIndexes([2, 1], columns: 2), [[0], [1]])
    }

    func testThreeUnitsHoldThreeSingles() {
        XCTAssertEqual(packRowIndexes([1, 1, 1], columns: 3), [[0, 1, 2]])
    }

    func testMixedSpansShareWhileTheyFit() {
        XCTAssertEqual(packRowIndexes([1, 2], columns: 3), [[0, 1]])
        XCTAssertEqual(packRowIndexes([2, 1], columns: 3), [[0, 1]])
        XCTAssertEqual(packRowIndexes([2, 2], columns: 3), [[0], [1]])
    }

    func testAnAppScreenStandsAlone() {
        XCTAssertEqual(packRowIndexes([1, nil, 1], columns: 2), [[0], [1], [2]])
    }

    func testWiderThanTheRowStandsAlone() {
        // A card dragged in from a wider lane, before the lane re-counts.
        XCTAssertEqual(packRowIndexes([3], columns: 2), [[0]])
    }

    func testNothingPacksToNoRows() {
        XCTAssertEqual(packRowIndexes([], columns: 2), [])
    }
}
