// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import XCTest
@testable import CCPUI

/// The pad's floating rail: the clamp is pure, the line reads are pure, the
/// AppKit application is prefix-only, and the anchor is wired like the other
/// monitors (custom center, canned measure) — so most of this proves numbers.
@MainActor
final class NoteFormatRailTests: XCTestCase {
    // MARK: - Clamp

    func testRailCentersOnMidContainerCaret() {
        // Caret mid 150, rail 134: top at 83.
        XCTAssertEqual(NoteFormatRail.clampedRailTop(caretMidY: 150, containerHeight: 300, railHeight: 134), 83)
    }

    func testRailDocksToTopWithEightPoints() {
        XCTAssertEqual(NoteFormatRail.clampedRailTop(caretMidY: 0, containerHeight: 300, railHeight: 134), 8)
    }

    func testRailDocksAboveTheToolbarFade() {
        // The bottom dock clears the 28pt fade plus 8: 300 - 36 - 134 = 130,
        // so the rail never parks over dissolving glyphs.
        XCTAssertEqual(NoteFormatRail.clampedRailTop(caretMidY: 300, containerHeight: 300, railHeight: 134), 130)
    }

    func testShortContainerPinsToTop() {
        // Nowhere for the rail to go: top dock wins over a negative max.
        XCTAssertEqual(NoteFormatRail.clampedRailTop(caretMidY: 50, containerHeight: 100, railHeight: 134), 8)
    }

    func testClampHonorsCustomEdges() {
        XCTAssertEqual(NoteFormatRail.clampedRailTop(caretMidY: 0, containerHeight: 300, railHeight: 134,
                                                     top: 0, bottom: 0), 0)
        XCTAssertEqual(NoteFormatRail.clampedRailTop(caretMidY: 300, containerHeight: 300, railHeight: 134,
                                                     top: 0, bottom: 0), 166)
    }

    func testRailHeightMatchesItsButtons() {
        // 2×4 padding + 5×22 buttons + 4×4 gaps: the number the clamp was
        // designed around, pinned so a button added without a clamp review
        // fails loudly here instead of overlapping the toolbar fade.
        XCTAssertEqual(NoteFormatRail.height, 134)
    }

    // MARK: - Heading read and cycle

    func testHeadingLevels() {
        XCTAssertEqual(NoteFormatRail.headingLevel(of: "# Big"), 1)
        XCTAssertEqual(NoteFormatRail.headingLevel(of: "## Medium"), 2)
        XCTAssertEqual(NoteFormatRail.headingLevel(of: "###### Tiny"), 6)
        XCTAssertEqual(NoteFormatRail.headingLevel(of: "plain body"), 0)
    }

    func testHeadingNeedsASpace() {
        XCTAssertEqual(NoteFormatRail.headingLevel(of: "##x"), 0)
        XCTAssertEqual(NoteFormatRail.headingLevel(of: "##"), 0)
    }

    func testSevenHashesIsBody() {
        XCTAssertEqual(NoteFormatRail.headingLevel(of: "####### x"), 0)
    }

    func testThreeSpaceIndentStillHeads() {
        XCTAssertEqual(NoteFormatRail.headingLevel(of: "   ## x"), 2)
    }

    func testFourSpaceIndentStillHeadsLikeTheEngine() {
        // The engine trims before reading and strips the indent on apply, so
        // the rail agrees with it rather than with strict Markdown.
        XCTAssertEqual(NoteFormatRail.headingLevel(of: "    ## x"), 2)
    }

    func testHeadingCycle() {
        XCTAssertEqual(NoteFormatRail.nextHeadingLevel(after: 0), 2)
        XCTAssertEqual(NoteFormatRail.nextHeadingLevel(after: 1), 2)
        XCTAssertEqual(NoteFormatRail.nextHeadingLevel(after: 2), 3)
        XCTAssertEqual(NoteFormatRail.nextHeadingLevel(after: 3), 1)
        XCTAssertEqual(NoteFormatRail.nextHeadingLevel(after: 4), 2)
    }

    // MARK: - To-do transform

    func testTodoToggle() {
        XCTAssertEqual(NoteFormatRail.todoToggledLine("- [ ] buy milk"), "- [x] buy milk")
        XCTAssertEqual(NoteFormatRail.todoToggledLine("- [x] buy milk"), "- [ ] buy milk")
        XCTAssertEqual(NoteFormatRail.todoToggledLine("- buy milk"), "- [ ] buy milk")
        XCTAssertEqual(NoteFormatRail.todoToggledLine("buy milk"), "- [ ] buy milk")
    }

    func testUnknownCheckboxIsLeftAlone() {
        XCTAssertEqual(NoteFormatRail.todoToggledLine("- [X] buy milk"), "- [X] buy milk")
        XCTAssertEqual(NoteFormatRail.todoToggledLine("- [note] buy milk"), "- [note] buy milk")
    }

    func testSelectedLineStripsIndentAndNewline() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        textView.string = "  ## headed\nbody\n"
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertEqual(NoteFormatRail.selectedLine(in: textView), "## headed")
    }

    // MARK: - To-do application

    func testTodoPrefixesABodyLine() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        textView.string = "buy milk"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        NoteFormatRail.toggleTodo(in: textView)
        XCTAssertEqual(textView.string, "- [ ] buy milk")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 0))
    }

    func testTodoChecksAndUnchecksInPlace() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        textView.string = "- [ ] buy milk"
        textView.setSelectedRange(NSRange(location: 10, length: 0))
        NoteFormatRail.toggleTodo(in: textView)
        XCTAssertEqual(textView.string, "- [x] buy milk")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 10, length: 0))
        NoteFormatRail.toggleTodo(in: textView)
        XCTAssertEqual(textView.string, "- [ ] buy milk")
    }

    func testTodoKeepsTheIndent() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        textView.string = "  - buy milk"
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        NoteFormatRail.toggleTodo(in: textView)
        XCTAssertEqual(textView.string, "  - [ ] buy milk")
    }

    func testTodoLeavesUnknownCheckbox() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        textView.string = "- [X] buy milk"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        NoteFormatRail.toggleTodo(in: textView)
        XCTAssertEqual(textView.string, "- [X] buy milk")
    }

    /// The load-bearing property: only prefix characters are ever edited, so
    /// a link's metadata rides the shift instead of being rewritten away.
    func testTodoPreservesLinkAttributes() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        textView.string = "see details"
        textView.textStorage?.addAttribute(.link, value: "https://example.com",
                                           range: NSRange(location: 4, length: 7))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        NoteFormatRail.toggleTodo(in: textView)
        XCTAssertEqual(textView.string, "- [ ] see details")
        let value = textView.textStorage?.attribute(.link, at: 10, effectiveRange: nil) as? String
        XCTAssertEqual(value, "https://example.com")
    }

    // MARK: - Focus reclaim

    func testRestoreFocusClaimsUnfocusedPad() {
        let focus = PanelFocus()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let textView = NSTextView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(textView)
        focus.notesTextView = textView
        window.makeFirstResponder(nil)

        NoteFormatRail.restoreNoteFocus(to: focus)

        XCTAssertTrue(window.firstResponder === textView)
    }

    func testRestoreFocusKeepsAFocusedPad() {
        let focus = PanelFocus()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let textView = NSTextView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(textView)
        focus.notesTextView = textView
        XCTAssertTrue(window.makeFirstResponder(textView))

        NoteFormatRail.restoreNoteFocus(to: focus)

        XCTAssertTrue(window.firstResponder === textView)
    }

    func testRestoreFocusWithoutAPadIsANoop() {
        NoteFormatRail.restoreNoteFocus(to: PanelFocus())
        NoteFormatRail.restoreNoteFocus(to: nil)
    }

    // MARK: - Anchor wiring

    /// The update recorder: a box the anchor's callback shares with the test.
    private final class UpdateBox {
        var values: [CGFloat?] = []
    }

    private func makeAnchor(center: NotificationCenter, box: UpdateBox) -> RailCaretMonitor {
        let anchor = RailCaretMonitor(center: center, measure: { _ in 42 })
        anchor.onUpdate = { box.values.append($0) }
        return anchor
    }

    private func scrolledTextView() -> (NSScrollView, NSTextView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let textView = NSTextView(frame: scrollView.contentView.bounds)
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    func testAnchorReportsOnSelectionChange() {
        let center = NotificationCenter()
        let box = UpdateBox()
        let anchor = makeAnchor(center: center, box: box)
        let (_, textView) = scrolledTextView()
        anchor.track(textView)

        XCTAssertTrue(anchor.isWatching)
        center.post(name: NSTextView.didChangeSelectionNotification, object: textView)

        XCTAssertEqual(box.values.count, 2) // track's refresh plus the post
        XCTAssertEqual(box.values[1], 42)
    }

    func testAnchorIgnoresOtherViews() {
        let center = NotificationCenter()
        let box = UpdateBox()
        let anchor = makeAnchor(center: center, box: box)
        let (_, tracked) = scrolledTextView()
        let (_, other) = scrolledTextView()
        anchor.track(tracked)
        box.values.removeAll()

        center.post(name: NSTextView.didChangeSelectionNotification, object: other)

        XCTAssertTrue(box.values.isEmpty)
        _ = tracked
    }

    func testAnchorReportsOnScroll() {
        let center = NotificationCenter()
        let box = UpdateBox()
        let anchor = makeAnchor(center: center, box: box)
        let (scrollView, textView) = scrolledTextView()
        anchor.track(textView)
        box.values.removeAll()

        center.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        XCTAssertEqual(box.values.count, 1)
        XCTAssertEqual(box.values[0], 42)
    }

    func testUntrackClearsAndStops() {
        let center = NotificationCenter()
        let box = UpdateBox()
        let anchor = makeAnchor(center: center, box: box)
        let (_, textView) = scrolledTextView()
        anchor.track(textView)
        box.values.removeAll()

        anchor.untrack()

        XCTAssertFalse(anchor.isWatching)
        XCTAssertEqual(box.values.count, 1)
        XCTAssertNil(box.values[0])
        center.post(name: NSTextView.didChangeSelectionNotification, object: textView)
        XCTAssertEqual(box.values.count, 1, "untracked anchor stays quiet")
    }

    func testTrackNilIsANoop() {
        let anchor = RailCaretMonitor(center: NotificationCenter(), measure: { _ in 42 })
        anchor.track(nil)
        XCTAssertFalse(anchor.isWatching)
    }

    // MARK: - Bus scoping

    func testBusNamesScopePerDocument() {
        let bus = MarkdownNoteEditor.formatBus(for: "pad-a")
        XCTAssertEqual(bus.applyBoldRequest, NoteFormatRequest.bold(for: "pad-a"))
        XCTAssertEqual(bus.applyItalicRequest, NoteFormatRequest.italic(for: "pad-a"))
        XCTAssertEqual(bus.applyHeadingRequest, NoteFormatRequest.heading(for: "pad-a"))
        XCTAssertEqual(bus.applyUnorderedListRequest, NoteFormatRequest.bullet(for: "pad-a"))
    }

    func testBusNamesDifferAcrossDocuments() {
        XCTAssertNotEqual(NoteFormatRequest.bold(for: "pad-a"), NoteFormatRequest.bold(for: "pad-b"))
        XCTAssertNotEqual(MarkdownNoteEditor.formatBus(for: "pad-a").applyBoldRequest,
                          MarkdownNoteEditor.formatBus(for: "pad-b").applyBoldRequest)
    }

    // MARK: - Shared caret geometry

    private func linedTextView() -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        textView.string = "aaa\nbbb\nccc"
        return textView
    }

    func testGeometryDescendsLineOrder() {
        let textView = linedTextView()
        guard let first = caretLineRect(for: textView, at: 1),
              let second = caretLineRect(for: textView, at: 5),
              let third = caretLineRect(for: textView, at: 9)
        else { return XCTFail("caret lines must measure") }
        XCTAssertGreaterThan(first.height, 0)
        XCTAssertLessThan(first.midY, second.midY)
        XCTAssertLessThan(second.midY, third.midY)
    }

    func testGeometryMeasuresASelectionStart() {
        let textView = linedTextView()
        textView.setSelectedRange(NSRange(location: 4, length: 3))
        let rect = caretLineRect(for: textView, at: textView.selectedRange().location)
        XCTAssertNotNil(rect)
        XCTAssertGreaterThan(rect?.height ?? 0, 0)
    }

    func testGeometryMeasuresDocumentEnd() {
        let textView = linedTextView()
        let rect = caretLineRect(for: textView, at: (textView.string as NSString).length)
        XCTAssertNotNil(rect)
    }

    func testGeometryMeasuresAnEmptyDocument() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        textView.string = ""
        XCTAssertNotNil(caretLineRect(for: textView, at: 0))
    }

    func testGeometryNeedsTextKit2() {
        let container = NSTextContainer()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200),
                                  textContainer: container)
        XCTAssertNil(textView.textLayoutManager, "this stack is TextKit 1 by construction")
        XCTAssertNil(caretLineRect(for: textView, at: 0))
    }
}
