// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit

/// A bare return in the pad starts a new block; shift+return stays a newline
/// inside the same one — Craft's rule, not Markdown's (ccp-inoq).
///
/// The distinction lives in the TEXT, never the splitter: the monitor turns a
/// bare return into a paragraph break (`\n\n`) at the caret, so the block AST
/// the sync diffs against keeps reading blank lines as the only boundary. If
/// the splitter cut on single newlines instead, every Craft block holding a
/// soft break would churn on every sync and the loop would never quiet.
///
/// Upstream is untouched — its text view keeps default AppKit behaviour, and
/// this watches from outside it. Shift+return still routes to
/// `insertLineBreak:` exactly as before.
@MainActor
final class ParagraphReturnMonitor {
    private let monitors: EventMonitors
    /// The key window's first responder while it is a text view. Field
    /// editors and modal panels are excluded in `handle(_:)` — the only
    /// real `NSTextView` in the app is the pad editor, so a bare return
    /// never expands anywhere else.
    private let editor: () -> NSTextView?
    private var monitor: Any?

    init(monitors: EventMonitors = .system,
         editor: @escaping () -> NSTextView? = { NSApp.keyWindow?.firstResponder as? NSTextView }) {
        self.monitors = monitors
        self.editor = editor
    }

    var isWatching: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        // No `?? event` fallback here: optional chaining flattens, so a
        // swallowed nil would read as a vanished self and every expanded
        // return would ALSO reach the editor as a second break.
        monitor = monitors.addLocal(.keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        guard let monitor else { return }
        monitors.remove(monitor)
        self.monitor = nil
    }

    /// The monitor's decision. A swallowed return inserts through the text
    /// view itself, so undo behaves as if the break had always been two
    /// newlines. A return at a line start additionally steps the caret back
    /// onto the new empty line — without it the caret would ride down with
    /// the pushed text and typing would prepend to that line instead of
    /// filling the break.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard Self.isBareReturn(event),
              let textView = editor(),
              // The pad's own view, never a field editor: single-line fields
              // borrow a shared NSTextView, and a return there commits (tab
              // rename) or confirms (save panel) rather than breaking text.
              !textView.isFieldEditor,
              textView.isEditable,
              !textView.hasMarkedText(),
              // A modal panel (e.g. scratchpad Export) has the key; its
              // fields answer their own returns.
              NSApp?.modalWindow == nil
        else { return event }
        let string = textView.string as NSString
        let range = textView.selectedRange()
        let lineRange = string.paragraphRange(for: NSRange(location: min(range.location, string.length),
                                                           length: 0))
        var line = string.substring(with: lineRange)
        while line.last?.isNewline == true { line.removeLast() }
        switch Self.lineReturn(line: line as NSString,
                               caret: range.location - lineRange.location) {
        case .plain:
            let atLineStart = range.length == 0
                && (range.location == 0 || string
                    .substring(with: NSRange(location: range.location - 1, length: 1)) == "\n")
            textView.insertText("\n\n", replacementRange: range)
            if atLineStart {
                textView.setSelectedRange(NSRange(location: textView.selectedRange().location - 1,
                                                  length: 0))
            }
        case .insert(let suffix):
            textView.insertText(suffix, replacementRange: range)
        case .replace(let lineRelative, let text, let caretOffset):
            var absolute = NSRange(location: lineRange.location + lineRelative.location,
                                   length: lineRelative.length)
            if range.length > 0 {
                // A selection is never left behind: select-all on `- Buy`
                // must replace the line, not mint beside it.
                absolute = NSUnionRange(absolute, range)
            }
            textView.insertText(text, replacementRange: absolute)
            // Clamped: a multi-line selection can swallow past the caret the
            // line logic computed.
            let end = min(lineRange.location + caretOffset, (textView.string as NSString).length)
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }
        return nil
    }

    /// Return or keypad Enter with no combining modifier held. Only the four
    /// that combine with keystrokes count — the device-independent mask
    /// would also veto on CapsLock and swallow keypad Enter under its
    /// numeric-pad flag, both of which still mean return here.
    private static func isBareReturn(_ event: NSEvent) -> Bool {
        (event.keyCode == Self.returnKeyCode || event.keyCode == Self.keypadEnterKeyCode)
            && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }

    /// Virtual keycodes, layout-independent like the dismissal monitor's Esc —
    /// `characters` is not.
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76

    /// What a bare return does on one `\n`-delimited line. `caret` is the
    /// UTF-16 offset within `line`, like everything AppKit hands out.
    enum LineReturn: Equatable {
        /// Not a list line — the paragraph-break path.
        case plain
        /// Insert this at the caret (the newline included). Text after the
        /// caret becomes the new item's content, so a mid-line return splits
        /// the item exactly like Craft.
        case insert(String)
        /// Replace this line-relative range with `text`; the caret lands on
        /// `caretOffset`, also line-relative.
        case replace(NSRange, with: String, caretOffset: Int)
    }

    /// Craft's list returns: content mints the next item, an empty item ends
    /// (outdenting first when nested). A minted todo is always unchecked and
    /// a numbered marker increments — the new item is fresh work, never a
    /// copy of the old line's state.
    ///
    /// Deliberately strict about what counts as a list: digits need a
    /// delimiter AND a space (`2026`, `1.2`, bare `1.` stay text — deleting
    /// a version number on return would be vandalism), and a `-`/`[ ]`
    /// without its space is prose, not a marker. An ordered marker alone on
    /// a line is likewise text: unlike `-`, bare `1.` is far more often the
    /// start of a number than an empty item.
    static func lineReturn(line: NSString, caret: Int) -> LineReturn {
        let length = line.length
        let caret = min(max(caret, 0), length)
        var i = 0
        while i < length, Self.isSpaceOrTab(line.character(at: i)) {
            i += 1
        }
        let indent = line.substring(to: i)
        var nextMarker = ""
        var isOrdered = false
        if i < length {
            let c = line.character(at: i)
            if c == Self.dash || c == Self.star || c == Self.plus {
                nextMarker = line.substring(with: NSRange(location: i, length: 1))
                i += 1
            } else if c >= Self.zero, c <= Self.nine {
                let digits = i
                while i < length {
                    let e = line.character(at: i)
                    guard e >= Self.zero, e <= Self.nine else { break }
                    i += 1
                }
                guard i < length else { return .plain }
                let delim = line.character(at: i)
                guard delim == Self.dot || delim == Self.paren else { return .plain }
                let n = Int(line.substring(with: NSRange(location: digits, length: i - digits))) ?? 0
                nextMarker = "\(n + 1)\(delim == Self.dot ? "." : ")")"
                isOrdered = true
                i += 1
            } else {
                return .plain
            }
        } else {
            return .plain
        }
        // Past the marker a space must follow, unless the line ends here —
        // and only a bullet may end here (see above).
        if i < length {
            guard Self.isSpaceOrTab(line.character(at: i)) else {
                return .plain
            }
            i = Self.skipSpaces(line, from: i)
        } else if isOrdered {
            return .plain
        }
        var checkbox = ""
        if i + 2 < length, line.character(at: i) == Self.openBracket,
           line.character(at: i + 2) == Self.closeBracket {
            checkbox = " [ ]"
            i += 3
            if i < length {
                guard Self.isSpaceOrTab(line.character(at: i)) else {
                    return .plain
                }
                i = Self.skipSpaces(line, from: i)
            }
        }
        let contentStart = i
        let hasContent = !(line.substring(from: i) as String)
            .trimmingCharacters(in: .whitespaces).isEmpty
        guard hasContent else {
            // Marker-only: end the item. Nested outdents one level (two
            // spaces, Craft's level) with the caret following the line down;
            // flush removes the marker outright.
            if indent.isEmpty {
                return .replace(NSRange(location: 0, length: length), with: "", caretOffset: 0)
            }
            let outdentWidth = indent.hasPrefix("\t") ? 1 : min(2, indent.count)
            return .replace(NSRange(location: 0, length: outdentWidth), with: "",
                            caretOffset: length - outdentWidth)
        }
        let suffix = "\n\(indent)\(nextMarker)\(checkbox) "
        if caret < contentStart {
            // Inside the marker: the new item goes below it and the caret
            // stays in it — the original line keeps all of its text.
            return .replace(NSRange(location: contentStart, length: 0), with: suffix,
                            caretOffset: contentStart)
        }
        return .insert(suffix)
    }

    /// ASCII whitespace the list scanner treats as indent or padding.
    private static func isSpaceOrTab(_ c: UInt16) -> Bool {
        c == Self.space || c == Self.tab
    }

    private static func skipSpaces(_ line: NSString, from i: Int) -> Int {
        var i = i
        while i < line.length, isSpaceOrTab(line.character(at: i)) {
            i += 1
        }
        return i
    }

    // Marker bytes, named so the call-sites read without a code table.
    private static let space: UInt16 = 0x20
    private static let tab: UInt16 = 0x09
    private static let dash: UInt16 = 0x2D        // -
    private static let star: UInt16 = 0x2A        // *
    private static let plus: UInt16 = 0x2B        // +
    private static let zero: UInt16 = 0x30        // 0
    private static let nine: UInt16 = 0x39        // 9
    private static let dot: UInt16 = 0x2E         // .
    private static let paren: UInt16 = 0x29       // )
    private static let openBracket: UInt16 = 0x5B  // [
    private static let closeBracket: UInt16 = 0x5D // ]
}
