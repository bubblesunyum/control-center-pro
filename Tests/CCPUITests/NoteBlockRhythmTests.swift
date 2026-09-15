// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import XCTest
@testable import CCPUI

/// The pad's vertical rhythm lands on its ratios of the font's own natural
/// line height, at the size the pad uses and at one well away from it.
@MainActor
final class NoteBlockRhythmTests: XCTestCase {
    private func assertRatiosHold(atFontSize size: CGFloat,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let font = NSFont.systemFont(ofSize: size)
        let natural = font.ascender - font.descender + font.leading
        let rhythm = NoteEditorStyle.rhythm(forFontSize: size)
        XCTAssertEqual(rhythm.line, natural * NoteEditorStyle.lineHeightRatio, accuracy: 0.5,
                       "line step \(rhythm.line) misses its ratio at \(size)pt", file: file, line: line)
        XCTAssertEqual(rhythm.block, natural * NoteEditorStyle.blockSpacingRatio, accuracy: 0.5,
                       "block step \(rhythm.block) misses its ratio at \(size)pt", file: file, line: line)
    }

    func testBothStepsLandOnTheirRatiosAtThePadsOwnSize() {
        assertRatiosHold(atFontSize: NoteEditorStyle.fontSize)
    }

    func testBothStepsLandOnTheirRatiosAtALargerSize() {
        assertRatiosHold(atFontSize: 20)
    }

    func testABlockStandsFurtherOffThanALineDoes() {
        let rhythm = NoteEditorStyle.rhythm(forFontSize: NoteEditorStyle.fontSize)
        XCTAssertGreaterThan(rhythm.block, rhythm.line)
    }
}
