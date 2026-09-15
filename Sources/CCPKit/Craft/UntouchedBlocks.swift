// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Keeps a block the user never touched spelled exactly as it was stored.
///
/// The note editor reads the pad as a document and writes the whole document
/// back as markdown, in its own spelling: a tab indent comes back as two
/// spaces, Craft's `*****` rule as `***`. Each of those would be a changed
/// block to the push, rewriting Craft blocks nobody edited.
///
/// So a save is compared block for block — cut by ``CraftBlockSplitter``,
/// the same blocks the push sends — against what the editor saved the pad as
/// the moment it loaded. A block the editor still saves the same way is one
/// the user left alone, and it goes back as the stored bytes.
public enum UntouchedBlocks {
    /// The pad text for an editor save.
    ///
    /// - Parameters:
    ///   - saved: what the editor saves the document as now.
    ///   - loaded: what it saved the same document as when it loaded.
    ///   - source: the pad text it loaded.
    public static func restore(in saved: String, loaded: String, source: String) -> String {
        if saved == loaded { return source }
        let sourceSlices = CraftBlockSplitter.slices(in: source)
        let loadedSlices = CraftBlockSplitter.slices(in: loaded)
        // The editor read one block per stored block; if it did not, the
        // pairing is unknowable and the editor's own spelling is the answer.
        guard sourceSlices.count == loadedSlices.count else { return saved }
        let savedSlices = CraftBlockSplitter.slices(in: saved)
        let unchanged = unchangedPairs(loaded: loadedSlices.map(\.markdown),
                                       saved: savedSlices.map(\.markdown))
        let text = NSMutableString(string: saved)
        for (loadedIndex, savedIndex) in unchanged.reversed() {
            let original = sourceSlices[loadedIndex].markdown
            let slice = savedSlices[savedIndex]
            guard original != slice.markdown else { continue }
            let range = NSRange(location: slice.range.location, length: (slice.markdown as NSString).length)
            text.replaceCharacters(in: range, with: original)
        }
        return text as String
    }

    /// Index pairs of the blocks both lists share, in order: the longest
    /// common subsequence, so one edited or inserted block moves no other
    /// block's pairing.
    static func unchangedPairs(loaded: [String], saved: [String]) -> [(Int, Int)] {
        let difference = saved.difference(from: loaded)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        let keptLoaded = loaded.indices.filter { !removed.contains($0) }
        let keptSaved = saved.indices.filter { !inserted.contains($0) }
        return Array(zip(keptLoaded, keptSaved))
    }
}
