// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// Turning a ``NoteDocument`` into text an editor can show, and reading it
/// back out again.
///
/// A plain `TextEditor` can only draw what is in its string, so a list's
/// bullet and a to-do's checkbox are characters like any other. That makes
/// them the editor's problem rather than the note's: nothing in `CCPKit` knows
/// a bullet exists, and this is the one place that adds them and takes them
/// away again.
///
/// They are taken away by *counting*, never by an attribute. Text typed
/// against a marker inherits the marker's attributes, so an attribute saying
/// "this is decoration" would come to be worn by the user's own words — and
/// the reading would drop them.
enum NoteRendering {
    /// What is drawn in front of a block: how deep it sits, then how the
    /// reader knows what kind of block it is looking at.
    ///
    /// The indent is spaces for the same reason the bullet is a character —
    /// a plain `TextEditor` draws its string and nothing else. Two per level
    /// rather than four: a lane-width card has no room to spend, and a list
    /// may nest eight deep.
    static let indentation = "  "

    static func marker(for block: NoteBlock) -> String {
        String(repeating: indentation, count: block.indent) + marker(for: block.kind)
    }

    private static func marker(for kind: NoteBlock.Kind) -> String {
        switch kind {
        case .bulleted: "• "
        case .numbered: "– "
        case .todo(let isDone): isDone ? "☑ " : "☐ "
        case .quote: "▏ "
        case .divider: "──────────"
        case .paragraph, .heading, .code: ""
        }
    }

    // MARK: - Document → text

    static func text(for document: NoteDocument) -> AttributedString {
        var result = AttributedString()
        for (position, block) in document.blocks.enumerated() {
            var piece = AttributedString(position > 0 ? "\n" : "")
            piece += markerText(for: block)
            piece += body(of: block)
            piece.noteBlockKind = block.kind
            piece.noteBlockIndent = block.indent
            piece.noteBlockPosition = position
            result += piece
        }
        return result
    }

    private static func markerText(for block: NoteBlock) -> AttributedString {
        var marker = AttributedString(marker(for: block))
        marker.foregroundColor = .labelMuted
        return marker
    }

    private static func body(of block: NoteBlock) -> AttributedString {
        var body = AttributedString()
        for inline in block.inlines {
            var run = AttributedString(inline.text)
            run.inlinePresentationIntent = inline.style.marks.inlinePresentationIntent
            run.link = inline.style.link
            run.font = font(for: block.kind, marks: inline.style.marks)
            if case .quote = block.kind { run.foregroundColor = .labelMuted }
            body += run
        }
        return body
    }

    // MARK: - Text → document

    /// The editor's text as a note, with every marker this file drew shed
    /// again.
    static func document(from text: AttributedString) -> NoteDocument {
        let read = NoteDocument(text)
        return NoteDocument(blocks: read.blocks.map(shedMarker)).normalized()
    }

    /// One block with what was drawn in front of it taken back off — or, where
    /// that has been deleted into, the block reading as what is left of it.
    ///
    /// A marker is ordinary characters, so a backspace at the start of a list
    /// item eats into it. Leaving the block a list item would hand the user a
    /// half-bullet as their own text and never give it back.
    ///
    /// The indent and the glyph are shed separately, because a backspace lands
    /// in one or the other and means a different thing in each. In the indent
    /// it is an outdent — the item is still an item, one level shallower. In
    /// the glyph it is the end of being that kind of block, which is what
    /// every editor has taught people backspace at the front of a bullet does.
    /// Reading them as one marker instead would leave a bullet stranded in the
    /// user's own text the moment a space went missing in front of it.
    private static func shedMarker(from block: NoteBlock) -> NoteBlock {
        var block = block

        // The drawn indent is spaces, so what survives of it is the leading
        // spaces, and the levels are however many whole ones that still makes.
        let drawn = block.indent * indentation.count
        let spaces = block.plainText.prefix(drawn).prefix { $0 == " " }.count
        block = block.droppingFirst(spaces)
        block.indent = spaces / indentation.count

        let glyph = marker(for: block.kind)
        guard !glyph.isEmpty else { return block }
        let text = block.plainText
        if text.hasPrefix(glyph) { return block.droppingFirst(glyph.count) }

        var demoted = block.droppingFirst(text.commonPrefix(with: glyph).count)
        demoted.kind = .paragraph
        return demoted
    }

    // MARK: - Caret

    /// Where the caret sits counted in the note's own characters, so it can
    /// be found again after the text is redrawn with different markers.
    static func noteOffset(of index: AttributedString.Index, in text: AttributedString) -> Int {
        var start = 0
        for (position, block) in blocks(in: text).enumerated() {
            defer { start += block.contentLength + 1 }
            guard index < block.range.upperBound else { continue }
            let raw = text.characters.distance(from: block.range.lowerBound, to: index)
            // Sitting on the newline that opens this block means sitting at
            // the end of the line above, which is where the caret looks.
            if position > 0, raw == 0 { return start - 1 }
            return start + max(0, raw - block.leadingLength)
        }
        return max(0, start - 1)
    }

    static func index(atNoteOffset offset: Int, in text: AttributedString) -> AttributedString.Index {
        var start = 0
        for block in blocks(in: text) {
            let end = start + block.contentLength
            if offset <= end {
                return text.index(block.range.lowerBound,
                                  offsetByCharacters: block.leadingLength + max(0, offset - start))
            }
            start = end + 1
        }
        return text.endIndex
    }

    /// Which block a note offset falls in, and where a block's own text
    /// starts in that same counting. The commands work in blocks and the
    /// caret works in offsets, so one of them has to be able to speak the
    /// other's language, and offsets are already the currency the redraw uses.
    static func blockPosition(atNoteOffset offset: Int, in document: NoteDocument) -> Int {
        var start = 0
        for (position, block) in document.blocks.enumerated() {
            let end = start + block.plainText.count
            if offset <= end { return position }
            start = end + 1
        }
        return max(0, document.blocks.count - 1)
    }

    static func noteOffset(ofBlockAt position: Int, in document: NoteDocument) -> Int {
        document.blocks.prefix(position).reduce(0) { $0 + $1.plainText.count + 1 }
    }

    /// One block's extent in the text, and how much of it is not the note's
    /// own characters — the separating newline and the marker.
    private struct BlockExtent {
        let range: Range<AttributedString.Index>
        let leadingLength: Int
        let contentLength: Int
    }

    private static func blocks(in text: AttributedString) -> [BlockExtent] {
        var extents: [BlockExtent] = []
        var start: AttributedString.Index?
        var end = text.startIndex
        var position: Int?
        var block = NoteBlock(.paragraph)

        func close() {
            guard let lower = start else { return }
            let length = text.characters.distance(from: lower, to: end)
            let separator = extents.isEmpty ? 0 : 1
            let marker = marker(for: block)
            let markerLength = String(text[lower..<end].characters)
                .dropFirst(separator).hasPrefix(marker) ? marker.count : 0
            let leading = separator + markerLength
            extents.append(BlockExtent(range: lower..<end,
                                       leadingLength: leading,
                                       contentLength: max(0, length - leading)))
        }

        for run in text.runs {
            if run.noteBlockPosition != position {
                close()
                start = run.range.lowerBound
                position = run.noteBlockPosition
                block = NoteBlock(run.noteBlockKind ?? .paragraph, indent: run.noteBlockIndent ?? 0)
            }
            end = run.range.upperBound
        }
        close()
        return extents
    }

    // MARK: - Type
    //
    // Semantic styles rather than a point ramp: a note is prose the user reads
    // rather than a readout they glance at, so it is exactly the text that
    // should follow their Dynamic Type setting. Levels past the third share
    // the third's style — a heading that small in a lane-width card is a
    // weight, not a size.

    static func font(for kind: NoteBlock.Kind, marks: NoteInlineStyle.Marks) -> Font {
        var font: Font = switch kind {
        case .heading(let level): heading(level: level)
        case .code: .body.monospaced()
        default: marks.contains(.code) ? .body.monospaced() : .body
        }
        if marks.contains(.bold) { font = font.bold() }
        if marks.contains(.italic) { font = font.italic() }
        return font
    }

    private static func heading(level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline
        default: .body.weight(.semibold)
        }
    }
}
