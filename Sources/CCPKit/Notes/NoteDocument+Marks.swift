// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Turning a mark on and off over a selection.
///
/// On the attributed string rather than on `NoteDocument`, because that is
/// what an editor holds and what its selection addresses — converting to
/// blocks and back to apply a bold would throw away the caret.
public extension AttributedString {
    /// Whether every character in `ranges` already carries `mark`. Selecting
    /// text that is entirely bold and pressing bold should clear it, while a
    /// selection that is only partly bold should finish bold — the same rule
    /// every editor uses.
    func hasMark(_ mark: NoteInlineStyle.Marks, in ranges: [Range<Index>]) -> Bool {
        let populated = ranges.filter { !$0.isEmpty }
        guard !populated.isEmpty else { return false }
        return populated.allSatisfy { range in
            self[range].runs.allSatisfy {
                NoteInlineStyle.Marks($0.inlinePresentationIntent).contains(mark)
            }
        }
    }

    /// The string with `mark` turned on across `ranges`, or off if it was
    /// already on throughout.
    func togglingMark(_ mark: NoteInlineStyle.Marks, in ranges: [Range<Index>]) -> AttributedString {
        settingMark(mark, to: !hasMark(mark, in: ranges), in: ranges)
    }

    func settingMark(_ mark: NoteInlineStyle.Marks,
                     to isOn: Bool,
                     in ranges: [Range<Index>]) -> AttributedString {
        var result = self
        for range in ranges where !range.isEmpty {
            for run in result[range].runs {
                var marks = NoteInlineStyle.Marks(run.inlinePresentationIntent)
                if isOn { marks.insert(mark) } else { marks.remove(mark) }
                result[run.range].inlinePresentationIntent = marks.inlinePresentationIntent
            }
        }
        return result
    }
}

public extension NoteInlineStyle.Marks {
    /// Foundation's inline intent for these marks, and back. Public so an
    /// editor can read and write the same styling the document bridge does
    /// without restating the mapping.
    var inlinePresentationIntent: InlinePresentationIntent? {
        var intent: InlinePresentationIntent = []
        if contains(.bold) { intent.insert(.stronglyEmphasized) }
        if contains(.italic) { intent.insert(.emphasized) }
        if contains(.strikethrough) { intent.insert(.strikethrough) }
        if contains(.code) { intent.insert(.code) }
        return intent.isEmpty ? nil : intent
    }

    init(_ intent: InlinePresentationIntent?) {
        guard let intent else { self = []; return }
        var marks: NoteInlineStyle.Marks = []
        if intent.contains(.stronglyEmphasized) { marks.insert(.bold) }
        if intent.contains(.emphasized) { marks.insert(.italic) }
        if intent.contains(.strikethrough) { marks.insert(.strikethrough) }
        if intent.contains(.code) || intent.contains(.inlineHTML) { marks.insert(.code) }
        self = marks
    }
}
