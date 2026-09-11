// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import XCTest

@MainActor
final class StickySegmentsTests: XCTestCase {
    func testJoinIsolatesSeparatorsWithBlankLines() {
        XCTAssertEqual(
            StickySegments.join(["first sticky", "second sticky"]),
            "first sticky\n\n===\n\nsecond sticky")
    }

    func testSplitInvertsJoin() {
        let segments = ["first sticky", "# Title\n\nbody text", "- a\n- b"]
        XCTAssertEqual(StickySegments.split(StickySegments.join(segments)), segments)
    }

    func testEmptyDeskRoundTrips() {
        XCTAssertEqual(StickySegments.join([]), "")
        XCTAssertEqual(StickySegments.split(""), [])
    }

    func testBlankStickySurvivesAsABlankSegment() {
        XCTAssertEqual(StickySegments.split(StickySegments.join(["a", "", "b"])), ["a", "", "b"])
    }

    func testTrailingBlankShellsShedNoDanglingSeparator() {
        XCTAssertEqual(StickySegments.join(["a", ""]), "a")
        XCTAssertEqual(StickySegments.join([]), "")
    }

    func testPulledHardBreakDustDoesNotCreateSegments() {
        // A pull joins with hard breaks, so the separator line carries
        // trailing spaces — still one separator, not text.
        XCTAssertEqual(StickySegments.split("first sticky  \n===  \nsecond sticky"),
                       ["first sticky  ", "second sticky"])
    }

    func testSeparatorNamesItselfOnlyWholeLine() {
        // Naive, per the user's call: a === line always splits, but ===
        // inside a line never does.
        XCTAssertEqual(StickySegments.split("a === b"), ["a === b"])
        XCTAssertEqual(StickySegments.split("a\n===\nb"), ["a", "b"])
    }

    func testJoinedDeskSplitsIntoOwnSlices() {
        // The push contract: the shared splitter must hand the separator to
        // Craft as its own block, never glued to a neighbour (which the live
        // API would read as Setext H1 and eat).
        let slices = CraftBlockSplitter.slices(
            in: StickySegments.join(["first sticky", "second sticky"]))
            .map(\.markdown)
        XCTAssertEqual(slices, ["first sticky", "===", "second sticky"])
    }

    func testMultilineStickiesKeepTheirSlicesAroundSeparators() {
        let slices = CraftBlockSplitter.slices(
            in: StickySegments.join(["# Title\n\nbody", "- a\n- b"]))
            .map(\.markdown)
        XCTAssertEqual(slices, ["# Title", "body", "===", "- a", "- b"])
    }
}
