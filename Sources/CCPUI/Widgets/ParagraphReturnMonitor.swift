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
        let range = textView.selectedRange()
        let atLineStart = range.length == 0
            && (range.location == 0 || (textView.string as NSString)
                .substring(with: NSRange(location: range.location - 1, length: 1)) == "\n")
        textView.insertText("\n\n", replacementRange: range)
        if atLineStart {
            textView.setSelectedRange(NSRange(location: textView.selectedRange().location - 1,
                                              length: 0))
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
}
