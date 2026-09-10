// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import XCTest
@testable import CCPUI

/// The pad's vertical rhythm is solved for, not picked, so this is the test
/// that catches the solver drifting — at the size the pad actually uses and
/// at one well away from it.
@MainActor
final class NoteBlockRhythmTests: XCTestCase {
    private func assertRatioHolds(atFontSize size: CGFloat,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let rhythm = MarkdownNoteEditor.blockRhythm(forFontSize: size)
        let wanted = rhythm.line * MarkdownNoteEditor.blockSpacingRatio
        // The engine ceils the gap to whole points, so the step can only land
        // on the ratio to within that rounding.
        XCTAssertEqual(rhythm.block, wanted, accuracy: 1,
                       "block step \(rhythm.block) misses \(wanted) at \(size)pt",
                       file: file, line: line)
    }

    func testTheBlockStepLandsOnTheRatioAtThePadsOwnSize() {
        assertRatioHolds(atFontSize: MarkdownNoteEditor.fontSize)
    }

    func testTheBlockStepLandsOnTheRatioAtALargerSize() {
        assertRatioHolds(atFontSize: 20)
    }

    func testABlockStandsFurtherOffThanALineDoes() {
        let rhythm = MarkdownNoteEditor.blockRhythm(forFontSize: MarkdownNoteEditor.fontSize)
        XCTAssertGreaterThan(rhythm.block, rhythm.line)
    }
}
