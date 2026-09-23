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
    /// dirty; `base` advances its *remote* side to the fetch while its local
    /// side keeps, per block, what we last agreed — Craft's move is now in
    /// the pad but the merged text is not yet in Craft. Without that
    /// half-step every later pull re-derives the same merge and appends
    /// another conflict record while the push is still retrying.
    /// `hadConflict` means at least one block was changed differently on both
    /// sides — ours won, and `remoteText` is what history keeps so Craft's
    /// version stays reachable.
    case merged(text: String, hadConflict: Bool, remoteText: String, base: PadSyncBase)
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
        // ccp-ve18: an empty fetch never moves a non-empty pad. A fetch
        // that returns no writable blocks is what a moved-to-sub-page,
        // image-only, or otherwise unmodelled document looks like after
        // ccp-d8ec stopped descending into containers — and it is also what
        // a genuine full clear in Craft looks like. Adopting or merging it
        // would replace local text with "" (clean pad) or drop unedited
        // blocks beside a local edit (dirty pad), and store an empty base —
        // which blanked fusebox (2026-09-23) while Craft still held the
        // content. Stand the divergence instead: no snapshot, no base
        // write, no dirty bit. The next local edit owns the reconcile
        // through the push, like a cleared pad (ccp-o2qs) in reverse.
        if remoteText.isEmpty, !local.isEmpty { return .skip }
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
                theirBase: base.isAligned ? base.blocks.map(\.markdown) : nil,
                pinned: base.isAligned ? base.pinnedIndices : [])
            let text = join(result.merged)
            // The merge changing nothing and agreeing throughout means
            // Craft's move was already in the pad: the push carries the local
            // lead as usual. A disagreement still has to be recorded, even
            // when ours winning leaves the text where it was.
            guard text != local || result.hadConflict else { return .skip }
            // Carried onto the fetch by id (`rebased`), never by index: the
            // predecessor kept the old local text whole beside the new block
            // list, so a round where Craft gained or lost a block left the
            // base misaligned and the next push rewrote the document
            // (ccp-hu51).
            return .merged(text: text, hadConflict: result.hadConflict,
                           remoteText: remoteText,
                           base: base.rebased(on: fetched))
        }
    }
}
