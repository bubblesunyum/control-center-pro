// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// A note's body: an ordered list of blocks, each holding styled runs of text.
///
/// This is the shape the whole note capability trades in — the editor renders
/// it, `NoteStore` reads and writes it, and each backend maps it onto its own
/// blocks. Craft, Notion and Obsidian all model a document this way, which is
/// what makes it the right currency for a store that can be swapped for any of
/// them.
///
/// Flat with an indent level rather than a tree: nesting in the model would
/// only be flattened again at every backend, and an indent change stays a
/// change to one block instead of a move between arrays.
///
/// There is deliberately no block identity here. The content is the whole
/// value, so two documents that read the same are equal — which is the check
/// that tells a store whether anything needs writing at all. Pairing a block
/// with a backend's own id is that backend's bookkeeping, not the note's.
public struct NoteDocument: Codable, Hashable, Sendable {
    public var blocks: [NoteBlock]

    public init(blocks: [NoteBlock] = []) {
        self.blocks = blocks
    }

    public static let empty = NoteDocument()

    /// A document holding one empty paragraph — what a new pad starts as, and
    /// what an editor needs to have somewhere to put the caret.
    public static let blank = NoteDocument(blocks: [NoteBlock(.paragraph)])

    /// Whether the note reads as empty. A document of blank paragraphs is,
    /// which is what lets a pad opened and never typed in count as untouched.
    public var isEmpty: Bool {
        blocks.allSatisfy(\.isEmpty)
    }

    /// The note as unstyled text, for the pasteboard, search, and previews.
    public var plainText: String {
        blocks.map(\.plainText).joined(separator: "\n")
    }

    public init(plainText: String) {
        let lines = plainText.isEmpty ? [""] : plainText.components(separatedBy: .newlines)
        self.init(blocks: lines.map { NoteBlock(.paragraph, text: $0) })
    }

    /// The document with its blocks made well-formed: heading levels and
    /// indents in range, and adjacent runs sharing a style merged so two
    /// documents that read the same compare equal.
    ///
    /// Applied when a document is decoded or arrives from a backend, never
    /// inside `init(from:)` — decoding stays a faithful reading of what was
    /// stored, the same rule `PanelLayout` follows.
    public func normalized() -> NoteDocument {
        NoteDocument(blocks: blocks.map { $0.normalized() })
    }
}

/// One block: a paragraph, a heading, a list item, a rule.
///
/// `Kind` carries only what the block *is*. How big a heading draws is the
/// editor's business, so no font, colour or size appears here.
public struct NoteBlock: Codable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case paragraph
        case heading(level: Int)
        case bulleted
        case numbered
        case todo(isDone: Bool)
        case quote
        case code(language: String?)
        case divider
    }

    /// Deepest indent a block may sit at. Past this a list is unreadable in a
    /// lane-width card, and every backend has a limit of its own anyway.
    public static let maximumIndent = 8
    public static let headingLevels = 1...6

    public var kind: Kind
    public var indent: Int
    public var inlines: [NoteInline]

    public init(_ kind: Kind, indent: Int = 0, inlines: [NoteInline] = []) {
        self.kind = kind
        self.indent = indent
        self.inlines = inlines
    }

    /// A block of unstyled text — the common case, and what every test fixture
    /// would otherwise spell out.
    public init(_ kind: Kind, indent: Int = 0, text: String) {
        self.init(kind, indent: indent, inlines: text.isEmpty ? [] : [NoteInline(text)])
    }

    public var plainText: String {
        inlines.map(\.text).joined()
    }

    /// A rule is never empty: it has no text but is still something the user
    /// put there.
    public var isEmpty: Bool {
        kind != .divider && plainText.isEmpty
    }

    public func normalized() -> NoteBlock {
        var block = self
        block.indent = min(max(indent, 0), Self.maximumIndent)
        if case .heading(let level) = kind {
            block.kind = .heading(level: min(max(level, Self.headingLevels.lowerBound),
                                             Self.headingLevels.upperBound))
        }
        block.inlines = NoteInline.merged(inlines)
        return block
    }
}

/// A run of text sharing one style. A block is a sequence of these, in order.
public struct NoteInline: Codable, Hashable, Sendable {
    public var text: String
    public var style: NoteInlineStyle

    public init(_ text: String, style: NoteInlineStyle = NoteInlineStyle()) {
        self.text = text
        self.style = style
    }

    public init(_ text: String, marks: NoteInlineStyle.Marks) {
        self.init(text, style: NoteInlineStyle(marks: marks))
    }

    /// The runs with empty ones dropped and neighbours sharing a style joined.
    ///
    /// Typing splits runs constantly — a character added at a boundary arrives
    /// as its own run — so without this two identical-reading notes would
    /// compare unequal and the store would write on every keystroke.
    public static func merged(_ inlines: [NoteInline]) -> [NoteInline] {
        var merged: [NoteInline] = []
        for inline in inlines where !inline.text.isEmpty {
            if var last = merged.last, last.style == inline.style {
                last.text += inline.text
                merged[merged.count - 1] = last
            } else {
                merged.append(inline)
            }
        }
        return merged
    }
}

/// What a run of text looks like. Marks compose; a link is at most one.
///
/// New marks are added here and to the two conversions beside it — the block
/// kinds and the marks are the two places this model is meant to grow.
public struct NoteInlineStyle: Codable, Hashable, Sendable {
    public struct Marks: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let bold = Marks(rawValue: 1 << 0)
        public static let italic = Marks(rawValue: 1 << 1)
        public static let strikethrough = Marks(rawValue: 1 << 2)
        public static let code = Marks(rawValue: 1 << 3)
    }

    public var marks: Marks
    public var link: URL?

    public init(marks: Marks = [], link: URL? = nil) {
        self.marks = marks
        self.link = link
    }
}

public extension NoteDocument {
    /// Whether these two documents are laid out the same way — the same
    /// blocks, of the same kinds, at the same indents.
    ///
    /// What an editor asks to decide whether its text is still a fair drawing
    /// of the note. Typing inside a paragraph is not a change of structure;
    /// pressing return is, and a list item that has just appeared needs its
    /// bullet drawn.
    func hasSameStructure(as other: NoteDocument) -> Bool {
        blocks.count == other.blocks.count
            && zip(blocks, other.blocks).allSatisfy {
                $0.kind == $1.kind && $0.indent == $1.indent
            }
    }
}
