// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

// MARK: - Autoformatting

public extension NoteDocument {
    /// The document with the block at `position` turned into the block its
    /// markdown-style marker names, if that is what its text now is.
    ///
    /// Only that one block, because only that one block is where the user is:
    /// scanning the whole note would let a `"- "` left sitting in a paragraph
    /// somewhere else convert itself the next time anything at all was typed,
    /// and drag the caret across the note to it.
    ///
    /// The trigger has to be the block's whole text — the marker typed on a
    /// line with nothing else on it yet. Firing on a prefix of existing prose
    /// would rewrite a paragraph the user was only editing the front of, and
    /// there is no way to take an autoformat back short of an undo the editor
    /// would immediately redo. The block menu is how an existing line changes
    /// kind.
    func autoformatted(at position: Int) -> NoteDocument? {
        guard blocks.indices.contains(position) else { return nil }
        let block = blocks[position]
        guard case .paragraph = block.kind,
              let trigger = NoteBlock.Kind.autoformatTrigger(for: block.plainText)
        else { return nil }

        var updated = self
        var formatted = block.droppingFirst(trigger.length)
        formatted.kind = trigger.kind
        updated.blocks[position] = formatted.normalized()
        return updated
    }
}

public extension NoteBlock.Kind {
    /// The block kind `text` names, if it is exactly one of the markers a
    /// reader would write in markdown, and how long that marker is.
    ///
    /// The markers are the ones markdown already spends: whoever reaches for
    /// this has typed them somewhere else before.
    static func autoformatTrigger(for text: String) -> (kind: NoteBlock.Kind, length: Int)? {
        let hashes = text.prefix { $0 == "#" }.count
        if NoteBlock.headingLevels.contains(hashes), text.dropFirst(hashes) == " " {
            return (.heading(level: hashes), hashes + 1)
        }

        let digits = text.prefix(while: \.isNumber).count
        if digits > 0, text.dropFirst(digits) == ". " {
            return (.numbered, digits + 2)
        }

        return literalTriggers.first { text == $0.marker }
            .map { ($0.kind, $0.marker.count) }
    }

    private static let literalTriggers: [(marker: String, kind: NoteBlock.Kind)] = [
        ("- ", .bulleted),
        ("* ", .bulleted),
        ("+ ", .bulleted),
        ("[] ", .todo(isDone: false)),
        ("[ ] ", .todo(isDone: false)),
        ("[x] ", .todo(isDone: true)),
        ("> ", .quote),
        ("``` ", .code(language: nil)),
    ]
}

// MARK: - Block commands

public extension NoteDocument {
    /// The document with `kind` applied to the blocks at `positions`, or those
    /// blocks returned to paragraphs if they all carry it already.
    ///
    /// Toggling rather than setting because that is what a checked menu item
    /// promises: choosing the kind you are already in is how you leave it.
    func togglingKind(_ kind: NoteBlock.Kind, forBlocksAt positions: Range<Int>) -> NoteDocument {
        let positions = positions.clamped(to: blocks.indices)
        guard !positions.isEmpty else { return self }
        let isOn = positions.allSatisfy { blocks[$0].kind.isSameKind(as: kind) }
        var updated = self
        for position in positions {
            updated.blocks[position].kind = isOn ? .paragraph : kind
            updated.blocks[position] = updated.blocks[position].normalized()
        }
        return updated
    }

    /// The document with the blocks at `positions` moved `steps` deeper, or
    /// shallower for a negative `steps`, each clamped to the legal range.
    func indentingBlocks(at positions: Range<Int>, by steps: Int) -> NoteDocument {
        let positions = positions.clamped(to: blocks.indices)
        guard !positions.isEmpty, steps != 0 else { return self }
        var updated = self
        for position in positions {
            updated.blocks[position].indent += steps
            updated.blocks[position] = updated.blocks[position].normalized()
        }
        return updated
    }

    /// Whether every block at `positions` is already `kind` — what a menu item
    /// draws its checkmark from.
    func blocks(at positions: Range<Int>, allAre kind: NoteBlock.Kind) -> Bool {
        let positions = positions.clamped(to: blocks.indices)
        guard !positions.isEmpty else { return false }
        return positions.allSatisfy { blocks[$0].kind.isSameKind(as: kind) }
    }

    /// The deepest and shallowest indent across `positions`, which is what
    /// decides whether indenting any further is possible.
    func indentRange(atBlocks positions: Range<Int>) -> ClosedRange<Int>? {
        let indents = positions.clamped(to: blocks.indices).map { blocks[$0].indent }
        guard let lowest = indents.min(), let deepest = indents.max() else { return nil }
        return lowest...deepest
    }
}

public extension NoteBlock.Kind {
    /// Whether two kinds are the same *kind*, ignoring what the user changes
    /// without leaving the kind — a to-do is a to-do whether or not it is
    /// ticked, and code is code in any language. A heading's level is not one
    /// of these: it is what tells one heading from another.
    func isSameKind(as other: NoteBlock.Kind) -> Bool {
        switch (self, other) {
        case (.todo, .todo), (.code, .code): true
        default: self == other
        }
    }
}
