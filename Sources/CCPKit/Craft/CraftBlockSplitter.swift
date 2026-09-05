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
/// editor reads as mid-construct. A list arrives as one node spanning its
/// items and Craft wants one block per item, so lists are descended into —
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
            case .blank:
                break
            default:
                appendSlice(ns: ns, range: block.range, to: &slices)
            }
        }
        return slices
    }

    private static func appendSlice(ns: NSString, range: NSRange, to slices: inout [CraftBlockSlice]) {
        var markdown = ns.substring(with: range)
        while markdown.last?.isNewline == true { markdown.removeLast() }
        guard !markdown.isEmpty else { return }
        slices.append(CraftBlockSlice(markdown: markdown, range: range))
    }
}
