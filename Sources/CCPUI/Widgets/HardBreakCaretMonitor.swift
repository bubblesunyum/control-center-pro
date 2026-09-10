// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit

/// The caret steps over a block boundary instead of into it.
///
/// The pad stores a boundary as two trailing spaces before the newline
/// (``HardBreak``), and those spaces are real characters: without this, End
/// leaves the caret two columns past the last letter, a right arrow at the
/// end of a line presses three times to reach the next one, and a click past
/// the text lands somewhere there is nothing to see. The text is right and
/// the caret is wrong, which is the definition of a thing to fix in the
/// caret (ccp-ra2l).
///
/// Upstream is untouched; this watches selection changes from outside the
/// text view like the return and delete monitors watch keys, and a boundary
/// is read off ``HardBreak/trailingRun(in:lineRange:)`` — the same test the
/// splitter cuts blocks on, so the caret and the sync can never disagree
/// about where a block ends.
@MainActor
final class HardBreakCaretMonitor {
    private let center: NotificationCenter
    private var observer: (any NSObjectProtocol)?

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    var isWatching: Bool { observer != nil }

    func start() {
        guard observer == nil else { return }
        observer = center.addObserver(forName: NSTextView.didChangeSelectionNotification,
                                      object: nil, queue: nil) { [weak self] note in
            MainActor.assumeIsolated { self?.handle(note) }
        }
    }

    func stop() {
        guard let observer else { return }
        center.removeObserver(observer)
        self.observer = nil
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    private func handle(_ note: Notification) {
        guard let textView = note.object as? NSTextView,
              // The pad's own view, never a field editor: the same scoping
              // the return and delete monitors use.
              !textView.isFieldEditor,
              textView.isEditable
        else { return }
        let old = note.userInfo?["NSOldSelectedCharacterRange"] as? NSRange
        let string = textView.string as NSString
        guard let landing = Self.landing(in: string,
                                         selection: textView.selectedRange(),
                                         previous: old)
        else { return }
        // Idempotent: neither landing sits inside a run, so the selection
        // change this causes finds nothing to do and the pair settles.
        textView.setSelectedRange(NSRange(location: landing, length: 0))
    }

    /// Where a caret that landed inside a boundary's spaces belongs, or nil
    /// when it is already somewhere visible.
    ///
    /// A one-character move is an arrow key and means "the next position",
    /// so it carries on past the boundary to the line below. Anything else —
    /// End, a click, a vertical move, a word jump — meant a place on *this*
    /// line, and the only place there is where the text stops.
    ///
    /// Ranges are left alone: a selection that covers the spaces is the
    /// user's, and a drag that snapped would fight the pointer.
    static func landing(in string: NSString, selection: NSRange, previous: NSRange?) -> Int? {
        guard selection.length == 0 else { return nil }
        let caret = selection.location
        guard caret <= string.length else { return nil }
        let lineRange = string.paragraphRange(for: NSRange(location: caret, length: 0))
        guard let run = boundarySpaces(in: string, lineRange: lineRange),
              caret > run.location, caret <= NSMaxRange(run)
        else { return nil }
        let steppedForward = previous.map { caret - $0.location == 1 && $0.length == 0 } ?? false
        guard steppedForward else { return run.location }
        // Past the newline, onto the next line — never past the end of the
        // document, where the boundary is the last thing in the text.
        return min(NSMaxRange(run) + 1, string.length)
    }

    /// The spaces on `lineRange` the caret must not sit inside: a boundary's
    /// trailing run, or the marker on an empty block.
    ///
    /// A block opened between two others is a line holding nothing but the
    /// marker, waiting for the text that will make it a block. Those spaces
    /// are not a boundary yet — nothing precedes them — but they are just as
    /// invisible, and a caret behind them types the block's first word two
    /// columns in. The marker EXACTLY is the test: the moment a space is
    /// typed the run is no longer it, so a line the user is deliberately
    /// indenting is their own again.
    private static func boundarySpaces(in string: NSString, lineRange: NSRange) -> NSRange? {
        if let run = HardBreak.trailingRun(in: string, lineRange: lineRange) { return run }
        var end = NSMaxRange(lineRange)
        while end > lineRange.location, isLineBreak(string.character(at: end - 1)) { end -= 1 }
        let line = NSRange(location: lineRange.location, length: end - lineRange.location)
        guard line.length == HardBreak.marker.utf16.count,
              string.substring(with: line) == HardBreak.marker
        else { return nil }
        return line
    }

    private static func isLineBreak(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D
    }
}
