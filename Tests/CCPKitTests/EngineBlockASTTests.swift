// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import MarkdownEngine
import XCTest

/// The fork seam ccp-aa5 exists for: the sync splitter must cut the pad with
/// the same grammar the editor styles with. These tests pin that the block
/// AST is reachable and that its ranges tile the document gap-free — the one
/// assumption ccp-xgl builds on.
final class EngineBlockASTTests: XCTestCase {
    func testBlocksTileTheDocumentGapFree() {
        let text = "# Standup\nShip the **markdown** spike today.\n\n- [x] parse\n- [ ] sync\n"
        let blocks = DocumentAST.parse(text)
        XCTAssertFalse(blocks.isEmpty)
        var cursor = 0
        for block in blocks {
            XCTAssertEqual(block.range.location, cursor,
                           "a gap or overlap before \(block)")
            cursor = NSMaxRange(block.range)
        }
        XCTAssertEqual(cursor, (text as NSString).length)
    }

    func testListItemsSplitPerLineWithCheckboxRanges() {
        let text = "- [x] done\n- [ ] open\n"
        let blocks = DocumentAST.parse(text)
        guard case .list(_, let items) = blocks.first else {
            return XCTFail("a two-item list must parse as one list block")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].checked)
        XCTAssertFalse(items[1].checked)
        XCTAssertNotNil(items[0].checkbox)
        XCTAssertNotNil(items[1].checkbox)
        XCTAssertEqual(items[0].contentRange.length, 4) // "done"
    }

    func testHeadingsCarryLevelAndMarkers() {
        let blocks = DocumentAST.parse("## Title\n")
        guard case .heading(let level, _, let markers, _) = blocks.first else {
            return XCTFail("expected a heading block")
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(markers.count, 1)
    }
}
