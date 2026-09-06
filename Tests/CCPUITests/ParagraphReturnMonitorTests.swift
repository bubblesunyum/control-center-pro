// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import XCTest
@testable import CCPUI

/// A bare return in the pad is a paragraph break; everything else reaches the
/// editor untouched. The splice goes through the text view, so these prove
/// the caret and the surrounding text, not just the swallowed event.
@MainActor
final class ParagraphReturnMonitorTests: XCTestCase {
    func testWatchingStopsWithTheSurface() {
        let events = FakeKeyMonitors()
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { nil }

        monitor.start()
        XCTAssertEqual(events.installed, 1)
        XCTAssertTrue(monitor.isWatching)

        monitor.start()
        XCTAssertEqual(events.installed, 1, "starting twice installs one monitor")

        monitor.stop()
        XCTAssertEqual(events.installed, 0)
        XCTAssertFalse(monitor.isWatching)
    }

    func testBareReturnBecomesAHardBreakAtTheCaret() {
        let events = FakeKeyMonitors()
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = "ab\ncd"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { textView }

        monitor.start()
        XCTAssertNil(events.send(keyCode: 36, modifiers: []), "a bare return is consumed")

        // At a line start the spaces harden the line above; the caret lands
        // on the new empty line, not the pushed text.
        XCTAssertEqual(textView.insertions, [.init(text: "  \n", range: NSRange(location: 2, length: 0))])
        XCTAssertEqual(textView.string, "ab  \n\ncd")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testReturnAtLineEndLeavesTheCaretInTheNewBlock() {
        let events = FakeKeyMonitors()
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = "ab"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { textView }

        monitor.start()
        XCTAssertNil(events.send(keyCode: 36, modifiers: []))

        XCTAssertEqual(textView.string, "ab  \n")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testReturnMidLineSplitsAndFollowsTheText() {
        let events = FakeKeyMonitors()
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = "ab"
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { textView }

        monitor.start()
        XCTAssertNil(events.send(keyCode: 36, modifiers: []))

        XCTAssertEqual(textView.string, "a  \nb")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 0),
                       "a mid-line split follows the pushed text, like every line editor")
    }

    func testReturnAboveABlankLineOpensANewLine() {
        // The boundary already exists: minting spaces would land the caret
        // on the next block, prepending to it.
        let events = FakeKeyMonitors()
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = "ab\n\ncd"
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { textView }

        monitor.start()
        XCTAssertNil(events.send(keyCode: 36, modifiers: []))

        XCTAssertEqual(textView.insertions, [.init(text: "\n", range: NSRange(location: 4, length: 0))])
        XCTAssertEqual(textView.string, "ab\n\n\ncd")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 0),
                       "the caret waits on the new empty line, not the pushed text")
    }

    func testReturnOnAnEmptyLineHardensTheLineAbove() {
        let events = FakeKeyMonitors()
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = "ab\n\ncd"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { textView }

        monitor.start()
        XCTAssertNil(events.send(keyCode: 36, modifiers: []))

        XCTAssertEqual(textView.insertions, [.init(text: "  \n", range: NSRange(location: 2, length: 0))])
        XCTAssertEqual(textView.string, "ab  \n\n\ncd")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testReturnInAnEmptyPadLeavesATypableLine() {
        let events = FakeKeyMonitors()
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { textView }

        monitor.start()
        XCTAssertNil(events.send(keyCode: 36, modifiers: []))

        XCTAssertEqual(textView.string, "  \n")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 0))
    }

    func testBareReturnReplacesASelection() {
        let events = FakeKeyMonitors()
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = "abcd"
        textView.setSelectedRange(NSRange(location: 1, length: 2))
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { textView }

        monitor.start()
        XCTAssertNil(events.send(keyCode: 36, modifiers: []))

        XCTAssertEqual(textView.string, "a  \nd")
    }

    func testKeypadEnterExpandsToo() {
        let events = FakeKeyMonitors()
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = "ab"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { textView }

        monitor.start()
        // Real keypad hardware carries the numeric-pad flag; that must not
        // read as a combination.
        XCTAssertNil(events.send(keyCode: 76, modifiers: .numericPad))
        XCTAssertEqual(textView.string, "ab  \n")
    }

    func testCapsLockDoesNotVetoTheBreak() {
        let events = FakeKeyMonitors()
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = "ab"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { textView }

        monitor.start()
        XCTAssertNil(events.send(keyCode: 36, modifiers: .capsLock))
        XCTAssertEqual(textView.string, "ab  \n")
    }

    func testFieldEditorKeepsItsReturn() {
        // Single-line fields borrow a shared NSTextView where return commits
        // (tab rename) or confirms (save panel) — never a paragraph break.
        let events = FakeKeyMonitors()
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = "ab"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.isFieldEditor = true
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { textView }

        monitor.start()
        XCTAssertNotNil(events.send(keyCode: 36, modifiers: []))
        XCTAssertEqual(textView.string, "ab")
        XCTAssertTrue(textView.insertions.isEmpty)
    }

    func testShiftReturnFallsThroughToASoftBreak() {
        let events = FakeKeyMonitors()
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = "ab"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { textView }

        monitor.start()
        let event = events.send(keyCode: 36, modifiers: .shift)
        XCTAssertNotNil(event, "shift+return stays a soft newline in the same block")
        XCTAssertEqual(textView.string, "ab", "nothing inserted on the way through")
        XCTAssertTrue(textView.insertions.isEmpty)
    }

    func testCommandReturnStaysUpstreams() {
        let events = FakeKeyMonitors()
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { nil }

        monitor.start()
        XCTAssertNotNil(events.send(keyCode: 36, modifiers: .command),
                        "upstream's wiki-link confirm keeps its key")
    }

    func testOrdinaryKeysAreLeftAlone() {
        let events = FakeKeyMonitors()
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { nil }

        monitor.start()
        XCTAssertNotNil(events.send(keyCode: 0, modifiers: []))
    }

    func testNoEditorFocusedPassesTheKeyOn() {
        let events = FakeKeyMonitors()
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { nil }

        monitor.start()
        XCTAssertNotNil(events.send(keyCode: 36, modifiers: []),
                        "a return outside the pad is not the pad's business")
    }

    func testReadOnlyEditorPassesTheKeyOn() {
        let events = FakeKeyMonitors()
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = "ab"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.isEditable = false
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { textView }

        monitor.start()
        XCTAssertNotNil(events.send(keyCode: 36, modifiers: []))
        XCTAssertEqual(textView.string, "ab")
    }

    // MARK: - Lists (ccp-1amf)

    /// Monitors under test. The installed closure holds its monitor weakly,
    /// so a helper-local one would vanish on return and every key would pass
    /// through — the test owns them, the way NotesWidget does in production.
    private var liveMonitors: [ParagraphReturnMonitor] = []

    private func listMonitor(text: String, caret: Int) -> (FakeKeyMonitors, RecordingTextView) {
        let events = FakeKeyMonitors()
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = text
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { textView }
        monitor.start()
        liveMonitors.append(monitor)
        return (events, textView)
    }

    func testReturnMintsTheNextBullet() {
        let (events, textView) = listMonitor(text: "- Buy milk", caret: 10)

        XCTAssertNil(events.send(keyCode: 36, modifiers: []))
        XCTAssertEqual(textView.string, "- Buy milk\n- ")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 13, length: 0))
    }

    func testReturnMidItemSplitsIt() {
        let (events, textView) = listMonitor(text: "- Buy", caret: 3)

        XCTAssertNil(events.send(keyCode: 36, modifiers: []))
        XCTAssertEqual(textView.string, "- B\n- uy")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 0))
    }

    func testSelectAllReplacesInsteadOfDuplicating() {
        // The reported bug: a selection starting in the marker minted beside
        // the selection instead of replacing it.
        let events = FakeKeyMonitors()
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = "- Buy"
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { textView }
        monitor.start()

        XCTAssertNil(events.send(keyCode: 36, modifiers: []))
        XCTAssertEqual(textView.string, "\n- ")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
    }

    func testMultiLineSelectionLeavesNothingBehind() {
        let events = FakeKeyMonitors()
        let textView = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.string = "- A\n- B"
        textView.setSelectedRange(NSRange(location: 0, length: 7))
        let monitor = ParagraphReturnMonitor(monitors: events.interface) { textView }
        monitor.start()

        XCTAssertNil(events.send(keyCode: 36, modifiers: []))
        XCTAssertEqual(textView.string, "\n- ")
    }

    func testReturnInTheMarkerOpensAnItemAbove() {
        let (events, textView) = listMonitor(text: "- Buy", caret: 0)

        XCTAssertNil(events.send(keyCode: 36, modifiers: []))
        XCTAssertEqual(textView.string, "- \n- Buy")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0),
                       "the caret stays in the new item; the original keeps its text")
    }

    func testReturnOnAnEmptyBulletRemovesIt() {
        let (events, textView) = listMonitor(text: "- ", caret: 2)

        XCTAssertNil(events.send(keyCode: 36, modifiers: []))
        XCTAssertEqual(textView.string, "")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testReturnOnANestedEmptyBulletOutdents() {
        let (events, textView) = listMonitor(text: "  - ", caret: 4)

        XCTAssertNil(events.send(keyCode: 36, modifiers: []))
        XCTAssertEqual(textView.string, "- ")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
    }

    func testReturnMintsAnUncheckedTodo() {
        let (events, textView) = listMonitor(text: "- [x] Done", caret: 10)

        XCTAssertNil(events.send(keyCode: 36, modifiers: []))
        XCTAssertEqual(textView.string, "- [x] Done\n- [ ] ")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 17, length: 0))
    }

    func testReturnOnAnEmptyTodoRemovesIt() {
        let (events, textView) = listMonitor(text: "- [ ]", caret: 5)

        XCTAssertNil(events.send(keyCode: 36, modifiers: []))
        XCTAssertEqual(textView.string, "")
    }

    func testReturnIncrementsANumberedMarker() {
        let (events, textView) = listMonitor(text: "3) Go", caret: 5)

        XCTAssertNil(events.send(keyCode: 36, modifiers: []))
        XCTAssertEqual(textView.string, "3) Go\n4) ")
    }

    func testShiftReturnInAListStaysSoft() {
        let (events, textView) = listMonitor(text: "- Buy", caret: 5)

        XCTAssertNotNil(events.send(keyCode: 36, modifiers: .shift),
                        "a soft continuation never mints")
        XCTAssertEqual(textView.string, "- Buy")
        XCTAssertTrue(textView.insertions.isEmpty)
    }

    func testProseThatLooksListyIsLeftAlone() {
        // A year, a bare number, a version, a dash without its space, a quote,
        // a heading: none mints, none is ever deleted.
        for text in ["2026", "1.", "1.2 X", "-x", "> quote", "## H", "```"] {
            let (events, textView) = listMonitor(text: text, caret: text.count)

            XCTAssertNil(events.send(keyCode: 36, modifiers: []), "still a hard break: \(text)")
            XCTAssertEqual(textView.string, "\(text)  \n", "kept verbatim: \(text)")
        }
    }
}

/// A text view that applies `insertText` by hand. A windowless `NSTextView`
/// silently drops it, which would make every splice assertion pass against
/// an unchanged string — the double records the call AND performs it, so the
/// tests prove the arguments as well as the decision.
@MainActor
private final class RecordingTextView: NSTextView {
    struct Insertion: Equatable {
        var text: String
        var range: NSRange
    }

    private(set) var insertions: [Insertion] = []

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = string as? String else { return }
        insertions.append(Insertion(text: text, range: replacementRange))
        self.string = (self.string as NSString).replacingCharacters(in: replacementRange, with: text)
        setSelectedRange(NSRange(location: replacementRange.location + (text as NSString).length,
                                 length: 0))
    }
}

/// Stands in for `NSEvent`'s local-monitor API with keys the test builds —
/// modifiers included, which the dismissal fake never needed.
@MainActor
private final class FakeKeyMonitors {
    private(set) var added = 0
    private(set) var removed = 0
    private var live: Set<Int> = []
    private var handler: ((NSEvent) -> NSEvent?)?

    var installed: Int { live.count }

    var interface: EventMonitors {
        EventMonitors(
            addGlobal: { _, _ in nil },
            addLocal: { [self] _, handler in
                self.handler = handler
                return token()
            },
            remove: { [self] handle in
                guard let handle = handle as? Int else { return XCTFail("not one of ours") }
                live.remove(handle)
                removed += 1
            }
        )
    }

    private func token() -> Any {
        added += 1
        live.insert(added)
        return added
    }

    @discardableResult
    func send(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
        return handler?(event)
    }
}
