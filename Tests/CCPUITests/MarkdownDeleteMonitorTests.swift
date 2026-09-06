// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import XCTest
@testable import CCPUI

/// Delete skips hidden markdown markers; backspace at a converted line
/// joins up as plain text; emptying a span takes its markers with it.
/// Shares the recording view and key-monitor doubles with the return tests.
@MainActor
final class MarkdownDeleteMonitorTests: XCTestCase {
    /// Monitors under test. The installed closure holds its monitor weakly,
    /// so a helper-local one would vanish on return — the test owns them,
    /// the way NotesWidget does in production.
    private var liveMonitors: [MarkdownDeleteMonitor] = []

    private func deleteMonitor(text: String, caret: Int, length: Int = 0)
        -> (FakeKeyMonitors, RecordingTextView) {
        let events = FakeKeyMonitors()
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = text
        textView.setSelectedRange(NSRange(location: caret, length: length))
        let monitor = MarkdownDeleteMonitor(monitors: events.interface) { textView }
        monitor.start()
        liveMonitors.append(monitor)
        return (events, textView)
    }

    // MARK: - Inline spans

    func testBackspaceAfterABoldCloserDeletesTheContentChar() {
        let (events, textView) = deleteMonitor(text: "**bold**", caret: 8)

        XCTAssertNil(events.send(keyCode: 51, modifiers: []))
        XCTAssertEqual(textView.string, "**bol**")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testBackspaceBeforeABoldCloserDeletesTheContentChar() {
        let (events, textView) = deleteMonitor(text: "**bold**", caret: 6)

        XCTAssertNil(events.send(keyCode: 51, modifiers: []))
        XCTAssertEqual(textView.string, "**bol**")
    }

    func testBackspaceDeletingTheLastBoldCharTakesTheMarkers() {
        let (events, textView) = deleteMonitor(text: "**d**", caret: 5)

        XCTAssertNil(events.send(keyCode: 51, modifiers: []),
                     "no invisible **** left behind for a second backspace")
        XCTAssertEqual(textView.string, "")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testBackspaceInsideBoldContentIsAnOrdinaryDelete() {
        let (events, textView) = deleteMonitor(text: "**bold**", caret: 4)

        XCTAssertNotNil(events.send(keyCode: 51, modifiers: []),
                        "no marker involved: AppKit owns it")
        XCTAssertTrue(textView.insertions.isEmpty)
        XCTAssertEqual(textView.string, "**bold**")
    }

    func testBackspaceAtABoldStartDeletesTheCharBefore() {
        let (events, textView) = deleteMonitor(text: "x**bold**", caret: 1)

        XCTAssertNil(events.send(keyCode: 51, modifiers: []))
        XCTAssertEqual(textView.string, "**bold**")
    }

    func testBackspaceBeforeASpanAtDocStartIsSwallowed() {
        let (events, textView) = deleteMonitor(text: "**bold**", caret: 0)

        XCTAssertNil(events.send(keyCode: 51, modifiers: []),
                     "passing through would eat a hidden marker")
        XCTAssertEqual(textView.string, "**bold**")
        XCTAssertEqual(textView.insertions.count, 1)
        XCTAssertEqual(textView.insertions.first?.range.length, 0)
    }

    func testBackspaceAtASpanBoundaryDeletesIntoTheEarlierSpan() {
        let (events, textView) = deleteMonitor(text: "**a** **b**", caret: 5)

        XCTAssertNil(events.send(keyCode: 51, modifiers: []))
        XCTAssertEqual(textView.string, " **b**",
                       "the visually-previous char was `a`, sole content: whole span goes")
    }

    func testBackspaceInsideAnAsteriskRunIsOrdinary() {
        // The engine reads `**a****b**` as one span with content `a****b`,
        // so a caret in the middle of the run is mid-content: AppKit owns it.
        let (events, textView) = deleteMonitor(text: "**a****b**", caret: 5)

        XCTAssertNotNil(events.send(keyCode: 51, modifiers: []))
        XCTAssertTrue(textView.insertions.isEmpty)
    }

    func testItalicAndCodeSkipTheirMarkersToo() {
        do {
            let (events, textView) = deleteMonitor(text: "*it* and `cd`", caret: 4)
            XCTAssertNil(events.send(keyCode: 51, modifiers: []))
            XCTAssertEqual(textView.string, "*i* and `cd`")
        }
        do {
            let (events, textView) = deleteMonitor(text: "*it* and `cd`", caret: 12)
            XCTAssertNil(events.send(keyCode: 51, modifiers: []))
            XCTAssertEqual(textView.string, "*it* and `c`")
        }
    }

    func testBackspaceAtLinkTextEndDeletesTextNotParens() {
        let (events, textView) = deleteMonitor(text: "[text](https://x.test)", caret: 5)

        XCTAssertNil(events.send(keyCode: 51, modifiers: []))
        XCTAssertEqual(textView.string, "[tex](https://x.test)")
    }

    func testBackspaceEmptyingLinkTextRemovesTheWholeLink() {
        let (events, textView) = deleteMonitor(text: "[t](https://x.test)", caret: 2)

        XCTAssertNil(events.send(keyCode: 51, modifiers: []))
        XCTAssertEqual(textView.string, "")
    }

    func testSelectingASpansContentTakesItsMarkers() {
        let (events, textView) = deleteMonitor(text: "**d**", caret: 2, length: 1)

        XCTAssertNil(events.send(keyCode: 51, modifiers: []))
        XCTAssertEqual(textView.string, "")
    }

    func testSelectingAcrossSpansPassesThrough() {
        let (events, textView) = deleteMonitor(text: "**ab**", caret: 1, length: 3)

        XCTAssertNotNil(events.send(keyCode: 51, modifiers: []),
                        "not exactly one span's content: AppKit owns it")
        XCTAssertTrue(textView.insertions.isEmpty)
    }

    func testLatexMarkersStayUpstreams() {
        // CCP renders no LaTeX (NoOp renderer): the `$` markers are
        // full-size visible, so deletes stay ordinary.
        let (events, textView) = deleteMonitor(text: "$a$", caret: 3)

        XCTAssertNotNil(events.send(keyCode: 51, modifiers: []))
        XCTAssertTrue(textView.insertions.isEmpty)
        XCTAssertEqual(textView.string, "$a$")
    }

    func testImageAltDeletesThroughItsHiddenWrapping() {
        do {
            let (events, textView) = deleteMonitor(text: "![b](c)", caret: 3)

            XCTAssertNil(events.send(keyCode: 51, modifiers: []))
            XCTAssertEqual(textView.string, "(c)",
                           "sole alt char takes the ref span; the url tail is separate text")
        }
        do {
            let (events, textView) = deleteMonitor(text: "a ![b](c) d", caret: 5)

            XCTAssertNil(events.send(keyCode: 117, modifiers: []))
            XCTAssertEqual(textView.string, "a ![b] d",
                           "sole url char takes the tail span, like any single-char span")
        }
    }

    func testImageUrlDeletesStayInTheUrl() {
        // The `(url)` tail is visible text: a caret inside it must never
        // teleport the delete back into the alt text.
        do {
            let (events, textView) = deleteMonitor(text: "![ab](cd)", caret: 8)

            XCTAssertNil(events.send(keyCode: 51, modifiers: []))
            XCTAssertEqual(textView.string, "![ab](c)")
        }
        do {
            let (events, textView) = deleteMonitor(text: "![ab](c)", caret: 7)

            XCTAssertNil(events.send(keyCode: 51, modifiers: []))
            XCTAssertEqual(textView.string, "![ab]",
                           "sole url char takes the tail span, alt text survives")
        }
    }

    func testEscapeDeletesAsOneUnit() {
        do {
            let (events, textView) = deleteMonitor(text: "a\\*b", caret: 2)

            XCTAssertNil(events.send(keyCode: 51, modifiers: []))
            XCTAssertEqual(textView.string, "\\*b")
        }
        do {
            let (events, textView) = deleteMonitor(text: "a\\*b", caret: 2)

            XCTAssertNil(events.send(keyCode: 117, modifiers: []))
            XCTAssertEqual(textView.string, "ab",
                           "forward into an escape clears marker and char together")
        }
    }

    func testEmojiDeletesByGraphemeNeverBySurrogate() {
        do {
            let (events, textView) = deleteMonitor(text: "**a😀**", caret: 5)

            XCTAssertNil(events.send(keyCode: 51, modifiers: []))
            XCTAssertEqual(textView.string, "**a**")
        }
        do {
            let (events, textView) = deleteMonitor(text: "**😀**", caret: 4)

            XCTAssertNil(events.send(keyCode: 51, modifiers: []))
            XCTAssertEqual(textView.string, "",
                           "the emoji was the whole content: markers go with it")
        }
    }

    // MARK: - Forward delete

    func testForwardDeleteAtASpanStartDeletesTheFirstContentChar() {
        let (events, textView) = deleteMonitor(text: "**bold**", caret: 0)

        XCTAssertNil(events.send(keyCode: 117, modifiers: []))
        XCTAssertEqual(textView.string, "**old**")
    }

    func testForwardDeleteOnTheLastCharTakesTheMarkers() {
        let (events, textView) = deleteMonitor(text: "**d**", caret: 0)

        XCTAssertNil(events.send(keyCode: 117, modifiers: []))
        XCTAssertEqual(textView.string, "")
    }

    func testForwardDeleteBeforeACloserSkipsToVisibleText() {
        let (events, textView) = deleteMonitor(text: "**bold**x", caret: 6)

        XCTAssertNil(events.send(keyCode: 117, modifiers: []))
        XCTAssertEqual(textView.string, "**bold**")
    }

    func testForwardDeleteAtDocEndAfterASpanIsSwallowed() {
        let (events, textView) = deleteMonitor(text: "**bold**", caret: 6)

        XCTAssertNil(events.send(keyCode: 117, modifiers: []),
                     "passing through would eat a hidden closer")
        XCTAssertEqual(textView.string, "**bold**")
    }

    // MARK: - Block prefix joins

    func testBackspaceOnAConvertedHeadingJoinsUpPlain() {
        let (events, textView) = deleteMonitor(text: "ab\n### H", caret: 7)

        XCTAssertNil(events.send(keyCode: 51, modifiers: []))
        XCTAssertEqual(textView.string, "abH")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
    }

    func testBackspaceOnADocStartHeadingJustUnconverts() {
        let (events, textView) = deleteMonitor(text: "### H", caret: 4)

        XCTAssertNil(events.send(keyCode: 51, modifiers: []))
        XCTAssertEqual(textView.string, "H")
    }

    func testBackspaceOnConvertedListsAndQuotesJoinsUp() {
        for (text, caret, expected) in [
            ("ab\n- item", 5, "abitem"),
            ("ab\n- [ ] t", 8, "abt"),
            ("ab\n- [x] t", 8, "abt"),
            ("ab\n1. x", 5, "abx"),
            ("ab\n> q", 4, "abq"),
        ] as [(String, Int, String)] {
            let (events, textView) = deleteMonitor(text: text, caret: caret)

            XCTAssertNil(events.send(keyCode: 51, modifiers: []), "join: \(text)")
            XCTAssertEqual(textView.string, expected, "join: \(text)")
        }
    }

    func testBackspaceOnNestedAndTabbedQuotesJoinsUp() {
        do {
            let (events, textView) = deleteMonitor(text: ">> foo", caret: 3)

            XCTAssertNil(events.send(keyCode: 51, modifiers: []))
            XCTAssertEqual(textView.string, "foo")
        }
        do {
            let (events, textView) = deleteMonitor(text: ">\tfoo", caret: 2)

            XCTAssertNil(events.send(keyCode: 51, modifiers: []))
            XCTAssertEqual(textView.string, "foo")
        }
    }

    func testForwardDeleteAtAConvertedLineStartStripsThePrefix() {
        do {
            let (events, textView) = deleteMonitor(text: "## Title", caret: 0)

            XCTAssertNil(events.send(keyCode: 117, modifiers: []))
            XCTAssertEqual(textView.string, "Title")
        }
        do {
            let (events, textView) = deleteMonitor(text: "- item", caret: 0)

            XCTAssertNil(events.send(keyCode: 117, modifiers: []))
            XCTAssertEqual(textView.string, "item")
        }
    }

    func testBackspaceBeforeBoldAfterAPrefixStopsAtNothingVisible() {
        // `## ` and `**` are all hidden: visually the caret sits at the
        // line start, so there is nothing to delete — and passing through
        // would eat a hidden marker.
        let (events, textView) = deleteMonitor(text: "## **b**", caret: 5)

        XCTAssertNil(events.send(keyCode: 51, modifiers: []))
        XCTAssertEqual(textView.string, "## **b**")
    }

    func testBackspaceJoiningPastAPrefixExposesItHonestly() {
        let (events, textView) = deleteMonitor(text: "ab\n- **b**", caret: 7)

        XCTAssertNil(events.send(keyCode: 51, modifiers: []))
        XCTAssertEqual(textView.string, "ab- **b**",
                       "the newline joins; the prefix rides along as plain text")
    }

    func testShiftBackspaceStillDeletesBackward() {
        let (events, textView) = deleteMonitor(text: "**bold**", caret: 8)

        XCTAssertNil(events.send(keyCode: 51, modifiers: .shift))
        XCTAssertEqual(textView.string, "**bol**")
    }

    func testBackspaceOnAnEmptyBulletUnconvertsInPlace() {
        let (events, textView) = deleteMonitor(text: "ab\n- ", caret: 4)

        XCTAssertNil(events.send(keyCode: 51, modifiers: []),
                     "the bullet goes, the line and its break stay")
        XCTAssertEqual(textView.string, "ab\n")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 0))
    }

    func testBackspaceOnADocStartEmptyBulletClearsIt() {
        let (events, textView) = deleteMonitor(text: "- ", caret: 2)

        XCTAssertNil(events.send(keyCode: 51, modifiers: []))
        XCTAssertEqual(textView.string, "")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testBackspaceOnEmptyConvertedLinesUnconvertsInPlace() {
        for (text, caret, expected, endCaret) in [
            ("ab\n### ", 7, "ab\n", 3),
            ("ab\n> ", 4, "ab\n", 3),
            ("ab\n1. ", 5, "ab\n", 3),
            ("ab\n- [ ] ", 8, "ab\n", 3),
            ("ab\n-   ", 4, "ab\n", 3),
        ] as [(String, Int, String, Int)] {
            let (events, textView) = deleteMonitor(text: text, caret: caret)

            XCTAssertNil(events.send(keyCode: 51, modifiers: []), "in place: \(text)")
            XCTAssertEqual(textView.string, expected, "in place: \(text)")
            XCTAssertEqual(textView.selectedRange(), NSRange(location: endCaret, length: 0),
                           "caret to the line start: \(text)")
        }
    }

    func testBackspaceAtTheLineStartJoinsNormally() {
        let (events, textView) = deleteMonitor(text: "ab\n### H", caret: 3)

        XCTAssertNotNil(events.send(keyCode: 51, modifiers: []),
                        "exactly at the line start is an ordinary join")
        XCTAssertTrue(textView.insertions.isEmpty)
    }

    func testLookalikeLinesAreLeftAlone() {
        // A year, a version, a dash without its space: no prefix, no span —
        // AppKit owns the key.
        for (text, caret) in [("2026", 4), ("1.2 X", 4), ("-x", 2)] as [(String, Int)] {
            let (events, textView) = deleteMonitor(text: text, caret: caret)

            XCTAssertNotNil(events.send(keyCode: 51, modifiers: []), "passthrough: \(text)")
            XCTAssertTrue(textView.insertions.isEmpty, "passthrough: \(text)")
        }
    }

    // MARK: - Guards

    func testWatchingStopsWithTheSurface() {
        let events = FakeKeyMonitors()
        let monitor = MarkdownDeleteMonitor(monitors: events.interface) { nil }

        monitor.start()
        XCTAssertEqual(events.installed, 1)
        XCTAssertTrue(monitor.isWatching)

        monitor.start()
        XCTAssertEqual(events.installed, 1, "starting twice installs one monitor")

        monitor.stop()
        XCTAssertEqual(events.installed, 0)
        XCTAssertFalse(monitor.isWatching)
    }

    func testOrdinaryKeysAreLeftAlone() {
        let events = FakeKeyMonitors()
        let monitor = MarkdownDeleteMonitor(monitors: events.interface) { nil }
        liveMonitors.append(monitor)

        monitor.start()
        XCTAssertNotNil(events.send(keyCode: 0, modifiers: []))
    }

    func testCommandDeletePassesThrough() {
        let (events, textView) = deleteMonitor(text: "**bold**", caret: 8)

        XCTAssertNotNil(events.send(keyCode: 51, modifiers: .command),
                        "kill-to-line-start keeps upstream behaviour")
        XCTAssertTrue(textView.insertions.isEmpty)
    }

    func testOptionDeletePassesThrough() {
        let (events, textView) = deleteMonitor(text: "**bold**", caret: 8)

        XCTAssertNotNil(events.send(keyCode: 51, modifiers: .option),
                        "word delete keeps upstream behaviour")
        XCTAssertTrue(textView.insertions.isEmpty)
    }

    func testNoEditorFocusedPassesTheKeyOn() {
        let events = FakeKeyMonitors()
        let monitor = MarkdownDeleteMonitor(monitors: events.interface) { nil }
        liveMonitors.append(monitor)

        monitor.start()
        XCTAssertNotNil(events.send(keyCode: 51, modifiers: []))
    }

    func testReadOnlyEditorPassesTheKeyOn() {
        let events = FakeKeyMonitors()
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = "**bold**"
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        textView.isEditable = false
        let monitor = MarkdownDeleteMonitor(monitors: events.interface) { textView }
        liveMonitors.append(monitor)

        monitor.start()
        XCTAssertNotNil(events.send(keyCode: 51, modifiers: []))
        XCTAssertTrue(textView.insertions.isEmpty)
    }

    func testFieldEditorKeepsItsDelete() {
        let events = FakeKeyMonitors()
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = "**bold**"
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        textView.isFieldEditor = true
        let monitor = MarkdownDeleteMonitor(monitors: events.interface) { textView }
        liveMonitors.append(monitor)

        monitor.start()
        XCTAssertNotNil(events.send(keyCode: 51, modifiers: []))
        XCTAssertTrue(textView.insertions.isEmpty)
    }
}
