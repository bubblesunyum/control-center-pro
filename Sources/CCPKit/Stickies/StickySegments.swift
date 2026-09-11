// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// The desk ↔ Craft document codec: the visible stickies ride one Craft page,
/// cut on the `===` line the app renders as its segmented-page separator.
///
/// Two facts from the live probe shape this (see
/// `craft-triple-equals-is-setext-inside-one-block`):
/// a standalone `===` text block round-trips verbatim through the API, but a
/// `===` line glued to text inside ONE posted block is parsed as Setext H1 —
/// the line above is promoted to `# …` and the separator vanishes. So `join`
/// isolates every separator with blank lines, and the push must send the
/// separator as its own block (which falls out of the shared splitter, never
/// by hand-cutting).
///
/// Naive on purpose, per the user's call: a sticky whose own text holds a
/// `===` line splits in Craft. Documented, not escaped.
public enum StickySegments {
    /// The separator line, trimmed on both sides before comparing — a pulled
    /// separator carries the join's hard-break trailing spaces.
    public static let separator = "==="

    public static func isSeparatorLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == separator
    }

    /// N sticky texts → one document's markdown. Blank lines around every
    /// separator keep it from parsing as a Setext underline for the line
    /// above. Trailing blank segments shed: a desk that shrank keeps its
    /// shells locally (see `setStickiesFromRemote`), and the document must
    /// not grow a dangling separator for shells it cannot see.
    public static func join(_ segments: [String]) -> String {
        var trimmed = segments
        while trimmed.last?.isEmpty == true { trimmed.removeLast() }
        return trimmed.joined(separator: "\n\n===\n\n")
    }

    /// One document's markdown → N sticky texts, in order. Segments keep
    /// their bytes verbatim — including hard-break trailing spaces a pull
    /// mints — by the same never-re-emit rule the block slices keep: what
    /// Craft confirmed is what the desk holds, so the next diff quiets.
    /// Only the join's blank-line padding is shed (leading/trailing newlines
    /// per segment). Empty documents and empty segments survive: `[]`
    /// round-trips to `""` and back, and a blank sticky stays a blank
    /// segment rather than vanishing.
    public static func split(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var segments: [String] = []
        var current: [String] = []
        // Preserve empty lines exactly: splitting on "\n" (not
        // components(separatedBy:)) keeps interior blank lines verbatim.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines {
            if isSeparatorLine(line) {
                segments.append(trimPadding(current.joined(separator: "\n")))
                current = []
            } else {
                current.append(line)
            }
        }
        segments.append(trimPadding(current.joined(separator: "\n")))
        return segments
    }

    private static func trimPadding(_ segment: String) -> String {
        var out = segment
        while out.hasPrefix("\n") { out.removeFirst() }
        while out.hasSuffix("\n") { out.removeLast() }
        return out
    }
}
