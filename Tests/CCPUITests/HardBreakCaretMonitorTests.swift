// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import XCTest
@testable import CCPUI

/// `ab  \ncd` — one boundary. The visible text stops at 2, the spaces run
/// 2..<4, the newline is 4, and the next line starts at 5.
private let boundary = "ab  \ncd" as NSString

@MainActor
final class HardBreakCaretMonitorTests: XCTestCase {
    private func landing(caret: Int, from previous: Int?) -> Int? {
        HardBreakCaretMonitor.landing(
            in: boundary,
            selection: NSRange(location: caret, length: 0),
            previous: previous.map { NSRange(location: $0, length: 0) })
    }

    func testARightArrowOffTheTextCarriesOnToTheNextLine() {
        XCTAssertEqual(landing(caret: 3, from: 2), 5)
    }

    func testALeftArrowOffTheNextLineLandsWhereTheTextStops() {
        XCTAssertEqual(landing(caret: 4, from: 5), 2)
    }

    func testEndStopsWhereTheTextStops() {
        // End moves further than one character, so it meant a place on this
        // line — not the line below.
        XCTAssertEqual(landing(caret: 4, from: 0), 2)
    }

    func testAClickPastTheTextLandsWhereTheTextStops() {
        XCTAssertEqual(landing(caret: 3, from: nil), 2)
    }

    func testACaretInTheTextIsLeftAlone() {
        XCTAssertNil(landing(caret: 1, from: 0))
        XCTAssertNil(landing(caret: 2, from: 1), "where the text stops is a real place")
    }

    func testACaretOnTheNextLineIsLeftAlone() {
        XCTAssertNil(landing(caret: 5, from: 4))
        XCTAssertNil(landing(caret: 6, from: 5))
    }

    func testASelectionIsNeverSnapped() {
        XCTAssertNil(HardBreakCaretMonitor.landing(in: boundary,
                                                   selection: NSRange(location: 1, length: 3),
                                                   previous: nil),
                     "a selection over the spaces is the user's")
    }

    func testALineWithoutABoundaryIsLeftAlone() {
        let soft = "ab \ncd" as NSString
        XCTAssertNil(HardBreakCaretMonitor.landing(in: soft,
                                                   selection: NSRange(location: 3, length: 0),
                                                   previous: NSRange(location: 2, length: 0)),
                     "one trailing space is the user's typing, not a boundary")
    }

    func testASpaceOnlyLineIsABlankSeparatorNotABoundary() {
        let blank = "   \ncd" as NSString
        XCTAssertNil(HardBreakCaretMonitor.landing(in: blank,
                                                   selection: NSRange(location: 2, length: 0),
                                                   previous: NSRange(location: 1, length: 0)))
    }

    func testABoundaryEndingTheDocumentDoesNotStepPastIt() {
        let trailing = "ab  \n" as NSString
        XCTAssertEqual(HardBreakCaretMonitor.landing(in: trailing,
                                                     selection: NSRange(location: 3, length: 0),
                                                     previous: NSRange(location: 2, length: 0)),
                       5, "the next line exists, and it is empty")
    }

    func testTheMonitorStopsWatchingWithTheSurface() {
        let center = NotificationCenter()
        let monitor = HardBreakCaretMonitor(center: center)
        XCTAssertFalse(monitor.isWatching)
        monitor.start()
        XCTAssertTrue(monitor.isWatching)
        monitor.stop()
        XCTAssertFalse(monitor.isWatching)
    }
}
