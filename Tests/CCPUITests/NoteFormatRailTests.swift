// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import XCTest
@testable import CCPUI

/// The pad's floating rail: the clamp and the heading cycle are pure, so this
/// proves numbers.
@MainActor
final class NoteFormatRailTests: XCTestCase {
    // MARK: - Clamp

    func testRailCentersOnMidContainerCaret() {
        // Caret mid 150, rail 134: top at 83.
        XCTAssertEqual(NoteFormatRail.clampedRailTop(caretMidY: 150, containerHeight: 300, railHeight: 134), 83)
    }

    func testRailDocksToTopWithEightPoints() {
        XCTAssertEqual(NoteFormatRail.clampedRailTop(caretMidY: 0, containerHeight: 300, railHeight: 134), 8)
    }

    func testRailDocksAboveTheToolbarFade() {
        // The bottom dock clears the 28pt fade plus 8: 300 - 36 - 134 = 130,
        // so the rail never parks over dissolving glyphs.
        XCTAssertEqual(NoteFormatRail.clampedRailTop(caretMidY: 300, containerHeight: 300, railHeight: 134), 130)
    }

    func testShortContainerPinsToTop() {
        // Nowhere for the rail to go: top dock wins over a negative max.
        XCTAssertEqual(NoteFormatRail.clampedRailTop(caretMidY: 50, containerHeight: 100, railHeight: 134), 8)
    }

    func testClampHonorsCustomEdges() {
        XCTAssertEqual(NoteFormatRail.clampedRailTop(caretMidY: 0, containerHeight: 300, railHeight: 134,
                                                     top: 0, bottom: 0), 0)
        XCTAssertEqual(NoteFormatRail.clampedRailTop(caretMidY: 300, containerHeight: 300, railHeight: 134,
                                                     top: 0, bottom: 0), 166)
    }

    func testRailHeightMatchesItsButtons() {
        // 2×4 padding + 5×22 buttons + 4×4 gaps: the number the clamp was
        // designed around, pinned so a button added without a clamp review
        // fails loudly here instead of overlapping the toolbar fade.
        XCTAssertEqual(NoteFormatRail.height, 134)
    }

    // MARK: - Heading cycle

    func testHeadingCycle() {
        XCTAssertEqual(NoteFormatRail.nextHeadingLevel(after: 0), 2)
        XCTAssertEqual(NoteFormatRail.nextHeadingLevel(after: 1), 2)
        XCTAssertEqual(NoteFormatRail.nextHeadingLevel(after: 2), 3)
        XCTAssertEqual(NoteFormatRail.nextHeadingLevel(after: 3), 1)
        XCTAssertEqual(NoteFormatRail.nextHeadingLevel(after: 4), 2)
    }
}
