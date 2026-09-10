// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPKit

final class HardBreakTests: XCTestCase {
    func testABoundaryIsLeftExactlyAsItIs() {
        XCTAssertEqual(HardBreak.normalized("ab  \ncd"), "ab  \ncd")
    }

    func testTextWithoutTrailingSpacesComesBackIdentical() {
        let text = "# Title\n\n- one\n- two\n"
        XCTAssertEqual(HardBreak.normalized(text), text)
    }

    func testStackedSpacesCollapseToOneBoundary() {
        XCTAssertEqual(HardBreak.normalized("ab    \n\ncd"), "ab  \n\ncd")
        XCTAssertEqual(HardBreak.normalized("ab      \n"), "ab  \n")
    }

    func testASpaceOnlyLineGoesEmpty() {
        XCTAssertEqual(HardBreak.normalized("  \nab"), "\nab")
        XCTAssertEqual(HardBreak.normalized("ab\n   \ncd"), "ab\n\ncd")
    }

    func testOneTrailingSpaceIsTheUsersOwnTyping() {
        XCTAssertEqual(HardBreak.normalized("ab \ncd"), "ab \ncd")
    }

    func testIndentSurvivesTheShed() {
        XCTAssertEqual(HardBreak.normalized("  - one    \n"), "  - one  \n")
        XCTAssertEqual(HardBreak.normalized("\tab  "), "\tab  ")
    }

    func testTheSplitterStillReadsAShedNoteTheSameWay() {
        let debris = "one    \n\ntwo      \nthree"
        XCTAssertEqual(CraftBlockSplitter.slices(in: HardBreak.normalized(debris)).map(\.markdown),
                       CraftBlockSplitter.slices(in: debris).map(\.markdown),
                       "shedding debris must never move a block boundary")
    }
}
