// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// One changed block: new markdown PUT over the id the base already holds.
public struct BlockUpdate: Equatable, Sendable {
    public var id: String
    public var markdown: String
}

/// One new block. Inserts sharing an anchor must be posted in plan order —
/// each lands after the previous one.
public struct BlockInsert: Equatable, Sendable {
    /// The sibling the block goes after, or nil for the start of the document.
    public var afterID: String?
    public var markdown: String
}

/// What a push spends: three batched requests (one PUT, one POST, one
/// DELETE), never the pad as one block and never one request per block.
/// Unchanged slices produce nothing at all — that silence is what preserves
/// the parts of a Craft block markdown cannot express.
public struct BlockPushPlan: Equatable, Sendable {
    public var updates: [BlockUpdate] = []
    public var inserts: [BlockInsert] = []
    public var deletes: [String] = []

    public var isEmpty: Bool {
        updates.isEmpty && inserts.isEmpty && deletes.isEmpty
    }

    /// Diff the pad against the base's own side of the agreement.
    ///
    /// **Both sequences are our markdown**, which is the whole reason this is
    /// trustworthy: the predecessor compared our slices against hashes of
    /// Craft's respelled form, so a block Craft rewrote could never come back
    /// equal and re-sent itself on every round forever (ccp-c2x5).
    ///
    /// Craft ids come from `base.blocks` by position, which only means
    /// anything while the two sides stand one-to-one. When Craft has split a
    /// block they do not, and the plan reposts the pad's blocks rather than
    /// guess an alignment — churn on a rare path, and the fetch that follows
    /// the push puts the base back in step.
    public static func plan(from base: PadSyncBase, to slices: [String]) -> BlockPushPlan {
        let old = base.localSlices
        guard old == slices else {
            return base.isAligned
                ? aligned(base: base, old: old, slices: slices)
                : rewrite(base: base, slices: slices)
        }
        return BlockPushPlan()
    }

    private static func aligned(base: PadSyncBase, old: [String],
                                slices: [String]) -> BlockPushPlan {
        let change = Alignment(base: old, side: slices)
        var plan = BlockPushPlan()
        for index in old.indices {
            plan.append(inserts: change.insertsBefore[index],
                        after: base.anchorID(before: index, changedBy: change))
            guard let replacement = change.replacements[index] else { continue }
            let block = base.blocks[index]
            // Pinned blocks are Craft's to write, never ours: an edit to one
            // in the pad is dropped rather than flattening what Craft cannot
            // take back (unrenderable-craft-blocks-are-read-only).
            guard block.isWritable else { continue }
            guard let first = replacement.first else {
                plan.deletes.append(block.id)
                continue
            }
            plan.updates.append(BlockUpdate(id: block.id, markdown: first))
            // A block that became several keeps its id on the first piece.
            plan.append(inserts: Array(replacement.dropFirst()), after: block.id)
        }
        plan.append(inserts: change.insertsBefore[old.count],
                    after: base.anchorID(before: old.count, changedBy: change))
        return plan
    }

    /// The base and the document no longer stand one-to-one: replace what we
    /// know we wrote and post the pad afresh. Pinned blocks are left where
    /// they are, so nothing Craft owns is lost to a realignment — and slices
    /// carrying tags the pad cannot render are never posted as new blocks,
    /// so an edited pinned block cannot duplicate itself as an insert while
    /// the original stays (ccp-occ revert-guard).
    private static func rewrite(base: PadSyncBase, slices: [String]) -> BlockPushPlan {
        let pinned = base.blocks.filter { !$0.isWritable }
        let writableSlices = slices.filter { !CraftBlockPolicy.isUnwritable(markdown: $0) }
        return BlockPushPlan(
            inserts: writableSlices.map { BlockInsert(afterID: pinned.last?.id, markdown: $0) },
            deletes: base.blocks.filter(\.isWritable).map(\.id))
    }

    private mutating func append(inserts markdowns: [String]?, after anchor: String?) {
        for markdown in markdowns ?? [] {
            inserts.append(BlockInsert(afterID: anchor, markdown: markdown))
        }
    }
}

private extension PadSyncBase {
    /// The Craft block a new slice lands behind: the nearest one before
    /// `index` that is still there after this round's deletes. Nil means the
    /// head of the document.
    func anchorID(before index: Int, changedBy change: Alignment) -> String? {
        var candidate = index - 1
        while candidate >= 0 {
            // A block being replaced keeps its id, so it still anchors; only
            // a straight delete stops being addressable.
            if change.replacements[candidate]?.isEmpty != true {
                return blocks[candidate].id
            }
            candidate -= 1
        }
        return nil
    }
}
