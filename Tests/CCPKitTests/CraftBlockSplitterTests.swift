// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPKit

/// The splitter cuts the pad into the verbatim slices a push sends to Craft:
/// same grammar the editor styles with, lists descended per item, blanks
/// skipped, bytes otherwise untouched.
final class CraftBlockSplitterTests: XCTestCase {
    func testSampleDocumentSplitsIntoVerbatimBlocks() {
        let text = "# Standup\nShip the **markdown** spike today.\n\n- [x] resolve the package\n- [ ] see it at 148pt\n```swift\nlet a = 1\n```\n> a quote\n> spanning two lines\n"
        let slices = CraftBlockSplitter.slices(in: text)
        XCTAssertEqual(slices.map(\.markdown), [
            "# Standup",
            "Ship the **markdown** spike today.",
            "- [x] resolve the package",
            "- [ ] see it at 148pt",
            "```swift\nlet a = 1\n```",
            "> a quote\n> spanning two lines",
        ])
    }

    /// ccp-hw0, the splitter half: both to-do states survive the cut
    /// byte-identical, markers and all. Foundation's parser ate the checkbox;
    /// this pins the regression at the layer that replaced it.
    func testTaskListStatesSurviveTheCutByteIdentical() {
        let text = "- [ ] open\n- [x] done\n"
        let slices = CraftBlockSplitter.slices(in: text)
        XCTAssertEqual(slices.map(\.markdown), ["- [ ] open", "- [x] done"])
        XCTAssertEqual(slices.map(\.markdown).joined(separator: "\n") + "\n", text)
        XCTAssertNotEqual(BlockSidecar.fingerprint(slices[0].markdown),
                          BlockSidecar.fingerprint(slices[1].markdown))
    }

    func testSoftWrappedLinesStayOneBlock() {
        // No blank line, no block boundary: consecutive lines are one
        // paragraph (Craft splits the same way — "a\n\nb" is two blocks,
        // "a\nb" is one).
        XCTAssertEqual(CraftBlockSplitter.slices(in: "line one\nline two\n").map(\.markdown),
                       ["line one\nline two"])
    }

    // MARK: - Hard breaks (ccp-qzzt)

    /// A bare return mints two trailing spaces; that line step is a block
    /// boundary, while a plain single newline stays a soft break. The marker
    /// never ships: slices keep the text, never the spaces.
    func testHardBreakSplitsParagraphWithoutShippingTheMarker() {
        let slices = CraftBlockSplitter.slices(in: "one  \ntwo\n")
        XCTAssertEqual(slices.map(\.markdown), ["one", "two"])
    }

    func testSoftBreaksBesideHardBreaksStayJoined() {
        XCTAssertEqual(CraftBlockSplitter.slices(in: "a\nb  \nc\n").map(\.markdown),
                       ["a\nb", "c"])
    }

    func testThreeSpacesAreStillAHardBreakOneSpaceIsNot() {
        XCTAssertEqual(CraftBlockSplitter.slices(in: "one   \ntwo\n").map(\.markdown),
                       ["one", "two"])
        XCTAssertEqual(CraftBlockSplitter.slices(in: "one \ntwo\n").map(\.markdown),
                       ["one \ntwo"])
    }

    func testWhitespaceOnlyLineIsABlankSeparatorNotAHardBreak() {
        XCTAssertEqual(CraftBlockSplitter.slices(in: "one\n  \ntwo\n").map(\.markdown),
                       ["one", "two"])
    }

    func testBackslashNewlineStaysSoft() {
        // Only the monitor mints boundaries and it mints spaces, so a path
        // like `C:\` at a line end must never split.
        XCTAssertEqual(CraftBlockSplitter.slices(in: "one\\\ntwo\n").map(\.markdown),
                       ["one\\\ntwo"])
    }

    func testTrailingHardBreakAtEndOfDocumentLeavesOneBlock() {
        XCTAssertEqual(CraftBlockSplitter.slices(in: "one  \n").map(\.markdown), ["one"])
    }

    func testHardBreakInsideACodeFenceDoesNotSplit() {
        let text = "```\none  \ntwo\n```\n"
        XCTAssertEqual(CraftBlockSplitter.slices(in: text).map(\.markdown), ["```\none  \ntwo\n```"])
    }

    func testHardBreakPiecesTileInOrder() {
        let text = "a\nb  \nc  \n\nd\n"
        let ns = text as NSString
        let slices = CraftBlockSplitter.slices(in: text)
        XCTAssertEqual(slices.map(\.markdown), ["a\nb", "c", "d"])
        var cursor = 0
        for slice in slices {
            XCTAssertGreaterThanOrEqual(slice.range.location, cursor, "slices must run in order")
            cursor = NSMaxRange(slice.range)
        }
    }

    func testBlankLinesAreSeparatorsNotBlocks() {        XCTAssertEqual(CraftBlockSplitter.slices(in: "\n\n\n").count, 0)
        XCTAssertEqual(CraftBlockSplitter.slices(in: "").count, 0)
        let slices = CraftBlockSplitter.slices(in: "one\n\n\ntwo\n")
        XCTAssertEqual(slices.map(\.markdown), ["one", "two"])
    }

    func testNestedItemKeepsItsIndentForCraftDepth() {
        let slices = CraftBlockSplitter.slices(in: "- parent\n  - child\n")
        XCTAssertEqual(slices.map(\.markdown), ["- parent", "  - child"])
    }

    func testOrderedItemsSplitPerLine() {
        let slices = CraftBlockSplitter.slices(in: "1. first\n2. second\n")
        XCTAssertEqual(slices.map(\.markdown), ["1. first", "2. second"])
    }

    func testSliceRangesTileInOrderWithoutOverlap() {
        let text = "# T\npara with émoji 🎉\n\n- a\n- b\n\ntail\n"
        let ns = text as NSString
        let slices = CraftBlockSplitter.slices(in: text)
        XCTAssertFalse(slices.isEmpty)
        var cursor = 0
        for slice in slices {
            XCTAssertGreaterThanOrEqual(slice.range.location, cursor, "slices must run in order")
            cursor = NSMaxRange(slice.range)
            XCTAssertEqual(ns.substring(with: slice.range).trimmingCharacters(in: .newlines),
                           slice.markdown)
        }
        XCTAssertLessThanOrEqual(cursor, ns.length)
    }
}
