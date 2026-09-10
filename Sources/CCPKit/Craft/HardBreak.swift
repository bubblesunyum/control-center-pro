// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// The pad's block boundary: two trailing spaces before a newline.
///
/// `CraftBlockSplitter` cuts on it and the note editor's return key mints it,
/// so a hard break is the one piece of markdown in the pad that is structure
/// rather than text. This is where the shape of it is written down.
public enum HardBreak {
    /// What a boundary looks like at the end of a line.
    public static let marker = "  "

    /// Sheds the trailing-space debris a note may have accumulated, without
    /// changing a single boundary.
    ///
    /// Until ccp-ra2l the return key could harden a line that was already
    /// hardened, stacking two more spaces onto it each time and leaving
    /// space-only lines behind on an empty pad. The splitter reads any run of
    /// two or more as one boundary, so none of that ever reached Craft — it
    /// just sat in the text where the caret had to walk over it. Runs of three
    /// or more collapse back to the marker; a space-only line goes empty; one
    /// or two trailing spaces are left exactly as they are, because those are
    /// a boundary or the user's own typing.
    public static func normalized(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var didChange = false
        let shed = lines.map { line -> String in
            let normalized = normalizedLine(line)
            if normalized != line { didChange = true }
            return normalized
        }
        // Unchanged text comes back as itself, so a note that never saw the
        // old return key is not rewritten and not marked dirty.
        return didChange ? shed.joined(separator: "\n") : text
    }

    /// The run of trailing spaces that makes `lineRange` a boundary, or nil
    /// when the line does not end in one.
    ///
    /// A boundary is two or more trailing spaces with real content before
    /// them on the same line — the same test the splitter cuts on, so a
    /// caller can never disagree with it about where a block ends. A
    /// whitespace-only line is a blank separator, never a boundary.
    ///
    /// The returned range is the spaces alone: its location is where the
    /// visible text stops, and its end is the line's last character.
    public static func trailingRun(in text: NSString, lineRange: NSRange) -> NSRange? {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location, isLineBreak(text.character(at: end - 1)) { end -= 1 }
        var contentEnd = end
        while contentEnd > lineRange.location, text.character(at: contentEnd - 1) == space {
            contentEnd -= 1
        }
        guard end - contentEnd >= marker.count else { return nil }
        var index = lineRange.location
        while index < contentEnd {
            let character = text.character(at: index)
            if character != space, character != tab { break }
            index += 1
        }
        guard index < contentEnd else { return nil }
        return NSRange(location: contentEnd, length: end - contentEnd)
    }

    private static func isLineBreak(_ character: unichar) -> Bool {
        character == newline || character == carriageReturn
    }

    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09
    private static let newline: unichar = 0x0A
    private static let carriageReturn: unichar = 0x0D

    private static func normalizedLine(_ line: String) -> String {
        guard line.hasSuffix(" ") else { return line }
        var content = Substring(line)
        while content.last == " " { content.removeLast() }
        guard !content.isEmpty else { return "" }
        guard line.count - content.count > marker.count else { return line }
        return content + marker
    }
}
