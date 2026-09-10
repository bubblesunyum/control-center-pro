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
    private func assertRatiosHold(atFontSize size: CGFloat,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let font = NSFont.systemFont(ofSize: size)
        let natural = font.ascender - font.descender + font.leading
        let rhythm = MarkdownNoteEditor.blockRhythm(forFontSize: size)
        // The engine rounds the line and the gap to whole points separately,
        // so each step can only land on its ratio to within that rounding.
        XCTAssertEqual(rhythm.line, natural * MarkdownNoteEditor.lineHeightRatio, accuracy: 1,
                       "line step \(rhythm.line) misses its ratio at \(size)pt",
                       file: file, line: line)
        XCTAssertEqual(rhythm.block, natural * MarkdownNoteEditor.blockSpacingRatio, accuracy: 1,
                       "block step \(rhythm.block) misses its ratio at \(size)pt",
                       file: file, line: line)
    }

    func testBothStepsLandOnTheirRatiosAtThePadsOwnSize() {
        assertRatiosHold(atFontSize: MarkdownNoteEditor.fontSize)
    }

    func testBothStepsLandOnTheirRatiosAtALargerSize() {
        assertRatiosHold(atFontSize: 20)
    }

    func testATighterRatioThanTheFontsOwnLeadingAddsNothing() {
        // The engine cannot express a line height below its own ceil, so the
        // solver must clamp rather than hand it a negative.
        XCTAssertGreaterThanOrEqual(
            MarkdownNoteEditor.lineHeightExtraSpacing(forFontSize: MarkdownNoteEditor.fontSize), 0)
    }

    func testABlockStandsFurtherOffThanALineDoes() {
        let rhythm = MarkdownNoteEditor.blockRhythm(forFontSize: MarkdownNoteEditor.fontSize)
        XCTAssertGreaterThan(rhythm.block, rhythm.line)
    }
}
