// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// What a pull decided for one pad. Pure data — the adapter spends it.
public enum PullDecision: Equatable, Sendable {
    /// Both sides still hold what they last agreed on: record the clock and
    /// touch nothing else.
    case converged
    /// Only Craft moved: replace the pad's text and advance the base.
    case adopt(text: String, base: PadSyncBase)
    /// Both moved, and the two edits combined. The pad takes `text` and goes
    /// dirty; the base waits for the push that follows, since neither side
    /// holds the merged text yet. `hadConflict` means at least one block was
    /// changed differently on both sides — ours won, and `remoteText` is what
    /// history keeps so Craft's version stays reachable.
    case merged(text: String, hadConflict: Bool, remoteText: String)
    /// First sight of this pad: record what each side holds as the agreement
    /// and move nothing. Both an unsynced pad and one upgraded from the
    /// superseded sidecar land here.
    case seed(PadSyncBase)
    /// Local leads and Craft did not move: the push owns it.
    case skip
}

/// The pull half of two-way sync: decide what one pad's fetch means.
///
/// Every question is answered against the recorded base (`PadSyncBase`) by
/// string equality, each side in its own dialect. Nothing is inferred from a
/// diff, which is what the predecessor did — it asked the push plan whether
/// the pad was clean, comparing our markdown against hashes of Craft's, so a
/// block Craft respelled read as a permanent local edit and every remote move
/// became a conflict (ccp-c2x5).
public enum CraftPull {
    /// Join block markdown into pad text. Hard breaks throughout — the same
    /// boundary the monitor mints (ccp-qzzt), so pulled text renders tight
    /// and resplits identically.
    public static func join(_ markdowns: [String]) -> String {
        markdowns.joined(separator: "  \n")
    }

    /// Decide for one pad.
    ///
    /// `stashIDs` are conflict copies an older build appended to the Craft
    /// document. They are excluded rather than deleted: they stay in Craft
    /// for the user to clear, and out of the pad meanwhile.
    public static func decide(local: String, base: PadSyncBase,
                              remote: [FetchedBlock],
                              stashIDs: Set<String> = []) -> PullDecision {
        let fetched = PadSyncBase.remote(remote, excluding: stashIDs)
        let remoteText = join(fetched.map(\.markdown))
        guard !base.isEmpty else {
            // No agreement on record. An empty pad has nothing to lose and
            // takes Craft's text; anything else keeps both sides exactly as
            // they are and simply starts remembering. A pre-existing
            // divergence then stands until one side next moves, which is the
            // one upgrade behaviour that can surprise nobody.
            let agreed = local.isEmpty ? remoteText : local
            let seeded = PadSyncBase(localText: agreed, blocks: fetched)
            if seeded.isEmpty { return .converged }
            return local.isEmpty && !remoteText.isEmpty
                ? .adopt(text: remoteText, base: seeded)
                : .seed(seeded)
        }
        let localMoved = local != base.localText
        let remoteMoved = PadSyncBase.remoteMoved(fetched, from: base.blocks)
        switch (localMoved, remoteMoved) {
        case (false, false):
            return .converged
        case (true, false):
            return .skip
        case (false, true):
            return .adopt(text: remoteText,
                          base: PadSyncBase(localText: remoteText, blocks: fetched))
        case (true, true):
            let result = ThreeWayMerge.merge(
                base: base.localSlices,
                ours: CraftBlockSplitter.slices(in: local).map(\.markdown),
                theirs: fetched.map(\.markdown),
                theirBase: base.isAligned ? base.blocks.map(\.markdown) : nil)
            let text = join(result.merged)
            // The merge changing nothing and agreeing throughout means
            // Craft's move was already in the pad: the push carries the local
            // lead as usual. A disagreement still has to be recorded, even
            // when ours winning leaves the text where it was.
            guard text != local || result.hadConflict else { return .skip }
            return .merged(text: text, hadConflict: result.hadConflict,
                           remoteText: remoteText)
        }
    }
}
