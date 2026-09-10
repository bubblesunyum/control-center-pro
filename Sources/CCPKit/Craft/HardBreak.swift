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

    private static func normalizedLine(_ line: String) -> String {
        guard line.hasSuffix(" ") else { return line }
        var content = Substring(line)
        while content.last == " " { content.removeLast() }
        guard !content.isEmpty else { return "" }
        guard line.count - content.count > marker.count else { return line }
        return content + marker
    }
}
