// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPKit

/// An editor save keeps every block the user did not edit byte for byte,
/// so the push sees only the blocks that actually changed.
final class UntouchedBlocksTests: XCTestCase {
    /// The pad as stored, and as the editor respells it on load.
    private let source = "# Plan  \n*****  \n- parent  \n\t- child  \nsnake_case"
    private let loaded = "# Plan\n\n***\n\n- parent\n  - child\n\nsnake_case"

    func testAnUneditedSaveIsTheStoredText() {
        XCTAssertEqual(UntouchedBlocks.restore(in: loaded, loaded: loaded, source: source), source)
    }

    func testEditingOneBlockChangesNoOtherBlock() {
        let saved = "# Plan\n\n***\n\n- parent\n  - child\n\nsnake_case, edited"
        let restored = UntouchedBlocks.restore(in: saved, loaded: loaded, source: source)
        XCTAssertEqual(CraftBlockSplitter.slices(in: restored).map(\.markdown),
                       ["# Plan", "*****", "- parent", "\t- child", "snake_case, edited"])
    }

    func testAnInsertedBlockKeepsTheBlocksAroundIt() {
        let saved = "# Plan\n\nnew line\n\n***\n\n- parent\n  - child\n\nsnake_case"
        let restored = UntouchedBlocks.restore(in: saved, loaded: loaded, source: source)
        XCTAssertEqual(CraftBlockSplitter.slices(in: restored).map(\.markdown),
                       ["# Plan", "new line", "*****", "- parent", "\t- child", "snake_case"])
    }

    func testADeletedBlockKeepsTheBlocksAroundIt() {
        let saved = "# Plan\n\n- parent\n  - child\n\nsnake_case"
        let restored = UntouchedBlocks.restore(in: saved, loaded: loaded, source: source)
        XCTAssertEqual(CraftBlockSplitter.slices(in: restored).map(\.markdown),
                       ["# Plan", "- parent", "\t- child", "snake_case"])
    }

    func testAnEditedBlockTakesTheEditorsSpelling() {
        let saved = "# Plan\n\n***\n\n- parent\n  - child, edited\n\nsnake_case"
        let restored = UntouchedBlocks.restore(in: saved, loaded: loaded, source: source)
        XCTAssertEqual(CraftBlockSplitter.slices(in: restored).map(\.markdown),
                       ["# Plan", "*****", "- parent", "  - child, edited", "snake_case"])
    }

    func testBlocksThatCannotBePairedKeepTheEditorsSave() {
        let saved = "one\n\ntwo, edited"
        XCTAssertEqual(UntouchedBlocks.restore(in: saved, loaded: "one two", source: "one  \ntwo"), saved)
    }

    func testAnEmptyPadTakesWhatWasTyped() {
        XCTAssertEqual(UntouchedBlocks.restore(in: "typed", loaded: "", source: ""), "typed")
    }

    /// ccp-giwa: the cached-slices path the editor bridge calls per
    /// keystroke agrees with the from-strings path. The identical-save case
    /// is excluded: the bridge answers it with a string compare before
    /// calling (trailing-space markers never survive the splitter, so only
    /// the verbatim fast path reproduces them).
    func testCachedSlicesMatchTheFromStringsPath() {
        let saves = [
            "# Plan\n\n***\n\n- parent\n  - child\n\nsnake_case, edited",
            "# Plan\n\nnew line\n\n***\n\n- parent\n  - child\n\nsnake_case",
            "# Plan\n\n- parent\n  - child\n\nsnake_case",
            "one\n\ntwo, edited",
            "typed",
        ]
        let sourceSlices = CraftBlockSplitter.slices(in: source)
        let loadedMarkdowns = CraftBlockSplitter.slices(in: loaded).map(\.markdown)
        for saved in saves {
            XCTAssertEqual(
                UntouchedBlocks.restore(in: saved, loadedMarkdowns: loadedMarkdowns,
                                        sourceSlices: sourceSlices),
                UntouchedBlocks.restore(in: saved, loaded: loaded, source: source),
                "for \(saved)")
        }
    }

    func testTheSplitterReadsTheSameBlocksInBothSpellings() {
        XCTAssertEqual(CraftBlockSplitter.slices(in: source).count,
                       CraftBlockSplitter.slices(in: loaded).count)
    }
}
