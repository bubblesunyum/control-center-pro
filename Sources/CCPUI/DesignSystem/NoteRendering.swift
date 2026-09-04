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
    /// What is drawn in front of a block, and how the reader knows what kind
    /// of block it is looking at.
    static func marker(for kind: NoteBlock.Kind) -> String {
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
        var marker = AttributedString(marker(for: block.kind))
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
        return NoteDocument(blocks: read.blocks.map { block in
            let marker = marker(for: block.kind)
            guard !marker.isEmpty, block.plainText.hasPrefix(marker) else { return block }
            return block.droppingFirst(marker.count)
        }).normalized()
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
        var kind = NoteBlock.Kind.paragraph

        func close() {
            guard let lower = start else { return }
            let length = text.characters.distance(from: lower, to: end)
            let separator = extents.isEmpty ? 0 : 1
            let marker = marker(for: kind)
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
                kind = run.noteBlockKind ?? .paragraph
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
