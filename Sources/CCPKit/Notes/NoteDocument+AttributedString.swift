// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

// MARK: - Attributes

/// The note model's own attributes, carried on an `AttributedString` so an
/// editor can hold a whole document in the one value SwiftUI's text editing
/// wants, and hand back something that converts cleanly.
///
/// Foundation's `PresentationIntent` covers most of what a block is, but not
/// all of it — a checked to-do has no intent to be spelled with — and it is
/// awkward to author, being shaped for what a markdown parser emits. So these
/// carry the block downwards, and `PresentationIntent` is only ever *read*,
/// where text arrives from Foundation's markdown parsing or a paste.
public enum NoteAttributes {
    public enum BlockKind: AttributedStringKey {
        public typealias Value = NoteBlock.Kind
        public static let name = "noteBlockKind"
    }

    public enum BlockIndent: AttributedStringKey {
        public typealias Value = Int
        public static let name = "noteBlockIndent"
    }

    /// Where the block sits in the document. Two paragraphs in a row are
    /// alike in every other attribute, so without this they would read back as
    /// one block with a newline in the middle.
    public enum BlockPosition: AttributedStringKey {
        public typealias Value = Int
        public static let name = "noteBlockPosition"
    }
}

public extension AttributeScopes {
    struct NoteAttributes: AttributeScope {
        public let noteBlockKind: CCPKit.NoteAttributes.BlockKind
        public let noteBlockIndent: CCPKit.NoteAttributes.BlockIndent
        public let noteBlockPosition: CCPKit.NoteAttributes.BlockPosition
        public let foundation: FoundationAttributes
    }

    var note: NoteAttributes.Type { NoteAttributes.self }
}

public extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.NoteAttributes, T>
    ) -> T { self[T.self] }
}

// MARK: - Document → AttributedString

public extension NoteDocument {
    /// The document as one attributed string, blocks separated by newlines.
    ///
    /// Inline styling goes on as the standard `inlinePresentationIntent` and
    /// `link` so anything that renders an `AttributedString` draws it without
    /// being taught the note model.
    var attributedString: AttributedString {
        var result = AttributedString()
        for (position, block) in blocks.enumerated() {
            if position > 0 {
                result += block.attributed(at: position, prefix: "\n")
            } else {
                result += block.attributed(at: position, prefix: "")
            }
        }
        return result
    }
}

private extension NoteBlock {
    /// The block, with its separating newline folded into it so no character
    /// of the document is left without a block to belong to.
    func attributed(at position: Int, prefix: String) -> AttributedString {
        var result = AttributedString(prefix)
        for inline in inlines {
            var run = AttributedString(inline.text)
            run.inlinePresentationIntent = inline.style.marks.inlinePresentationIntent
            run.link = inline.style.link
            result += run
        }
        result.noteBlockKind = kind
        result.noteBlockIndent = indent
        result.noteBlockPosition = position
        return result
    }
}

private extension NoteInlineStyle.Marks {
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

// MARK: - AttributedString → Document

public extension NoteDocument {
    /// The attributed string read back as blocks.
    ///
    /// Two shapes arrive here: one this model wrote, carrying `noteBlock*`
    /// attributes, and one Foundation's markdown parser produced, carrying
    /// `PresentationIntent`. Both are grouped the same way — by whichever
    /// marker says "this is still the same block" — so a paste of markdown and
    /// an edit of our own text come out alike.
    init(_ attributed: AttributedString) {
        var blocks: [NoteBlock] = []
        var current: (marker: BlockMarker, block: NoteBlock)?

        func finish() {
            guard var pending = current?.block else { return }
            let separator: NoteInline.BlockSeparator =
                current?.marker.carriesOwnAttributes == true ? .leading : .trailing
            pending.inlines = NoteInline.merged(pending.inlines.trimming(separator))
            blocks.append(pending.normalized())
            current = nil
        }

        for run in attributed.runs {
            let marker = BlockMarker(run)
            if current?.marker != marker {
                finish()
                current = (marker, NoteBlock(marker.kind, indent: marker.indent))
            }
            let style = NoteInlineStyle(marks: .init(run.inlinePresentationIntent), link: run.link)
            current?.block.inlines.append(NoteInline(String(attributed[run.range].characters), style: style))
        }
        finish()

        self.init(blocks: blocks.isEmpty ? NoteDocument.blank.blocks : blocks)
    }
}

/// What tells one block from the next in an attributed string, and what the
/// block turns out to be.
private struct BlockMarker: Equatable {
    /// Our own position attribute where we wrote it, otherwise the intent's
    /// identity — so a string from either source groups.
    let identity: Int
    let kind: NoteBlock.Kind
    let indent: Int
    /// Whether this block came from the note model's own attributes rather
    /// than from Foundation's markdown parsing. The two sources put the
    /// block-separating newline at opposite ends.
    let carriesOwnAttributes: Bool

    init(_ run: AttributedString.Runs.Run) {
        if let position = run.noteBlockPosition {
            identity = position
            kind = run.noteBlockKind ?? .paragraph
            indent = run.noteBlockIndent ?? 0
            carriesOwnAttributes = true
            return
        }
        carriesOwnAttributes = false
        let components = run.presentationIntent?.components ?? []
        identity = components.first?.identity ?? 0
        (kind, indent) = NoteBlock.Kind.resolving(components)
    }
}

private extension NoteBlock.Kind {
    /// A `PresentationIntent`'s components read as a block and an indent.
    /// Only ever used on text Foundation produced — nothing here writes an
    /// intent.
    static func resolving(
        _ components: [PresentationIntent.IntentType]
    ) -> (kind: NoteBlock.Kind, indent: Int) {
        var listDepth = 0
        var listIsOrdered: Bool?
        var quoteDepth = 0

        for component in components {
            switch component.kind {
            case .header(let level):
                return (.heading(level: level), 0)
            case .codeBlock(let languageHint):
                return (.code(language: languageHint), 0)
            case .thematicBreak:
                return (.divider, 0)
            case .orderedList:
                listDepth += 1
                if listIsOrdered == nil { listIsOrdered = true }
            case .unorderedList:
                listDepth += 1
                if listIsOrdered == nil { listIsOrdered = false }
            case .blockQuote:
                quoteDepth += 1
            default:
                break
            }
        }

        if let listIsOrdered {
            return (listIsOrdered ? .numbered : .bulleted, max(0, listDepth - 1))
        }
        if quoteDepth > 0 { return (.quote, max(0, quoteDepth - 1)) }
        return (.paragraph, 0)
    }
}

extension NoteInline {
    /// Which end of a block holds the newline that only separates it from its
    /// neighbour, and so is not the user's text.
    enum BlockSeparator {
        /// Written by `NoteDocument.attributedString`, which folds the newline
        /// into the front of each block after the first.
        case leading
        /// Left by Foundation's markdown parser, which ends a block with one —
        /// including the newline before a code block's closing fence.
        case trailing
    }
}

private extension Array where Element == NoteInline {
    /// Drops exactly the one separating newline, never more: further newlines
    /// are blank lines the user typed, and stripping those quietly deletes the
    /// end of a code block.
    func trimming(_ separator: NoteInline.BlockSeparator) -> [NoteInline] {
        var trimmed = self
        switch separator {
        case .leading:
            if var first = trimmed.first, first.text.hasPrefix("\n") {
                first.text.removeFirst()
                trimmed[0] = first
            }
        case .trailing:
            if var last = trimmed.last, last.text.hasSuffix("\n") {
                last.text.removeLast()
                trimmed[trimmed.count - 1] = last
            }
        }
        return trimmed.filter { !$0.text.isEmpty }
    }
}
