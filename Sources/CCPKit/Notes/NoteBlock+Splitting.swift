// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

extension NoteBlock {
    /// The block broken at any newline inside it, so pressing return in an
    /// editor starts a new block rather than putting a line break in this one.
    ///
    /// An editor has no reliable moment to intercept: the newline simply
    /// arrives carrying the attributes of the text before it, which would make
    /// a second paragraph part of the heading above it. Splitting on read is
    /// the same answer with nothing to intercept, and it lands where the user
    /// expects — return in a list item starts another item, return in a
    /// heading starts a paragraph under it.
    func splitAtNewlines(_ inlines: [NoteInline]) -> [NoteBlock] {
        // A code block is the one place a newline is content rather than a
        // boundary, which is the whole point of it.
        if case .code = kind {
            return [NoteBlock(kind, indent: indent, inlines: inlines)]
        }

        let groups = inlines.splitAtNewlines()
        guard groups.count > 1 else {
            return [NoteBlock(kind, indent: indent, inlines: inlines)]
        }
        return groups.enumerated().map { position, group in
            NoteBlock(position == 0 ? kind : kind.continuation, indent: indent, inlines: group)
        }
    }
}

public extension NoteBlock.Kind {
    /// What the next block is when the user presses return at the end of this
    /// one. A list carries on as a list; everything with a one-line shape of
    /// its own drops back to a paragraph.
    var continuation: NoteBlock.Kind {
        switch self {
        case .bulleted, .numbered, .quote: self
        case .todo: .todo(isDone: false)
        case .paragraph, .heading, .code, .divider: .paragraph
        }
    }
}

private extension Array where Element == NoteInline {
    /// The runs cut at every newline, keeping each piece's styling. An empty
    /// group is a blank line the user left, and stays one.
    func splitAtNewlines() -> [[NoteInline]] {
        var groups: [[NoteInline]] = [[]]
        for inline in self {
            let pieces = inline.text.components(separatedBy: "\n")
            for (index, piece) in pieces.enumerated() {
                if index > 0 { groups.append([]) }
                guard !piece.isEmpty else { continue }
                groups[groups.count - 1].append(NoteInline(piece, style: inline.style))
            }
        }
        return groups
    }
}

public extension NoteBlock {
    /// The block with the first `count` characters removed, styling intact.
    ///
    /// What an editor uses to shed a marker it drew in front of the block —
    /// a bullet, a checkbox. Counted rather than attributed on purpose: text
    /// typed against a marker inherits the marker's attributes, so an
    /// attribute cannot be what decides where the user's content starts.
    func droppingFirst(_ count: Int) -> NoteBlock {
        guard count > 0 else { return self }
        var remaining = count
        var kept: [NoteInline] = []
        for inline in inlines {
            guard remaining > 0 else { kept.append(inline); continue }
            let length = inline.text.count
            if length <= remaining {
                remaining -= length
            } else {
                kept.append(NoteInline(String(inline.text.dropFirst(remaining)), style: inline.style))
                remaining = 0
            }
        }
        return NoteBlock(kind, indent: indent, inlines: kept)
    }
}
