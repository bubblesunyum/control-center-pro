// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import MarkdownEngine

/// One Craft-sized block cut from the pad: a verbatim slice of what the user
/// typed, never re-emitted text. What Craft receives for a block is exactly
/// these bytes (modulo its own normalisation), so the class of round-trip bug
/// where regenerated markdown escapes or drops characters cannot occur.
public struct CraftBlockSlice: Equatable, Sendable {
    /// The slice text with its trailing line break trimmed. Leading
    /// whitespace is kept: list indentation maps onto Craft depth.
    public var markdown: String
    /// Where the slice came from, in the string it was cut from (UTF-16).
    public var range: NSRange

    public init(markdown: String, range: NSRange) {
        self.markdown = markdown
        self.range = range
    }
}

/// Cuts the pad's markdown into the blocks a push sends to Craft.
///
/// The cut uses the same grammar the editor styles with
/// (`DocumentAST.parse`), so a block boundary can never fall somewhere the
/// editor reads as mid-construct. Blank lines are one boundary; a hard break
/// (`two trailing spaces + newline`, ccp-qzzt) is the other: the pad turns a
/// bare return into a hard break at the keystroke, so by the time text
/// arrives here a hard-broken line step is a block boundary while a plain
/// lone newline stays a soft break inside one block. Cutting on ALL single
/// newlines instead would churn every multi-line block on every sync and the
/// loop would never quiet. A list arrives as one node spanning its items and
/// Craft wants one block per item, so lists are descended into —
/// one slice per item line, indent intact. Items are physical lines, so a
/// wrapped item's continuation ships as its own slice; Craft splits the same
/// way on write, and the sidecar is rebuilt from the write response, so the
/// pairing heals either way. Blank lines are separators, not blocks, and are
/// skipped.
public enum CraftBlockSplitter {
    /// Split `text` into verbatim block slices, in document order.
    public static func slices(in text: String) -> [CraftBlockSlice] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        var slices: [CraftBlockSlice] = []
        for block in DocumentAST.parse(text) {
            switch block {
            case .list(_, let items):
                for item in items {
                    appendSlice(ns: ns, range: item.range, to: &slices)
                }
            case .paragraph(let range, _), .blockquote(let range, _):
                for piece in hardBreakPieces(ns: ns, range: range) {
                    appendSlice(ns: ns, range: piece, to: &slices)
                }
            case .blank:
                break
            default:
                appendSlice(ns: ns, range: block.range, to: &slices)
            }
        }
        return slices
    }

    /// Cut a paragraph-ish range on its hard breaks. The engine's AST carries
    /// no hard-break node, so this scans the range's own text: a newline
    /// preceded by 2+ spaces on a line that holds other content is a
    /// boundary. A backslash before the newline is deliberately NOT one —
    /// only the monitor mints boundaries and it mints spaces, so a path like
    /// `C:\` at a line end must never split. Whitespace-only lines are blank
    /// separators, never hard breaks. Each piece ends where its content ends,
    /// so the boundary marker never ships to Craft and never fingerprints.
    static func hardBreakPieces(ns: NSString, range: NSRange) -> [NSRange] {
        var pieces: [NSRange] = []
        var pieceStart = range.location
        var lineStart = range.location
        let end = NSMaxRange(range)
        var cursor = range.location
        while cursor < end {
            guard ns.character(at: cursor) == Self.newline else { cursor += 1; continue }
            if isHardBreak(ns: ns, lineStart: lineStart, newlineAt: cursor) {
                pieces.append(NSRange(location: pieceStart,
                                      length: contentEnd(ns: ns, lineStart: lineStart,
                                                         newlineAt: cursor) - pieceStart))
                pieceStart = cursor + 1
            }
            cursor += 1
            lineStart = cursor
        }
        pieces.append(NSRange(location: pieceStart, length: end - pieceStart))
        return pieces
    }

    /// The content length of the line ending at `newlineAt`, without its
    /// hard-break spaces: the piece keeps the text, never the marker.
    private static func contentEnd(ns: NSString, lineStart: Int, newlineAt: Int) -> Int {
        var end = newlineAt
        while end > lineStart, ns.character(at: end - 1) == Self.space {
            end -= 1
        }
        return end
    }

    /// A hard break is 2+ trailing spaces AND non-space content before them
    /// on the same line. The content half is what keeps a whitespace-only
    /// line a blank separator instead of a boundary.
    private static func isHardBreak(ns: NSString, lineStart: Int, newlineAt: Int) -> Bool {
        var i = newlineAt
        while i > lineStart, ns.character(at: i - 1) == Self.space { i -= 1 }
        guard newlineAt - i >= 2 else { return false }
        var hasContent = false
        var k = lineStart
        while k < i {
            let c = ns.character(at: k)
            if c != Self.space, c != Self.tab, c != Self.carriageReturn {
                hasContent = true
                break
            }
            k += 1
        }
        return hasContent
    }

    private static let newline: unichar = 0x0A
    private static let carriageReturn: unichar = 0x0D
    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09

    private static func appendSlice(ns: NSString, range: NSRange, to slices: inout [CraftBlockSlice]) {
        var markdown = ns.substring(with: range)
        while markdown.last?.isNewline == true { markdown.removeLast() }
        // Trailing spaces at a slice's end are always a boundary marker —
        // the monitor's hard break or the pull's join — never content: in
        // CommonMark they carry no other meaning. Stripping them keeps the
        // marker from shipping to Craft and fingerprinting, whichever block
        // kind the slice is. Interior lines are untouched, so fenced code
        // keeps its bytes.
        while markdown.last == " " || markdown.last == "\t" { markdown.removeLast() }
        guard !markdown.isEmpty else { return }
        slices.append(CraftBlockSlice(markdown: markdown, range: range))
    }
}
