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
    /// block they do not, and the plan falls back to `realign`, which walks
    /// the two lists together instead of trusting the index.
    public static func plan(from base: PadSyncBase, to slices: [String]) -> BlockPushPlan {
        let old = base.localSlices
        guard old == slices else {
            return base.isAligned
                ? aligned(base: base, old: old, slices: slices)
                : realign(base: base, slices: slices)
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

    /// The base and the document no longer stand one-to-one, so no slice
    /// index names a block id. Walk the two lists together and write the
    /// least that reconciles them: our writable slices in order against
    /// Craft's writable blocks in order, PUT where the pad's text has
    /// actually changed, POST what is left over, DELETE only the blocks the
    /// pad has no slice for.
    ///
    /// **Every id that can stay, stays.** The predecessor deleted every
    /// writable block and reposted the whole pad behind the last pinned one,
    /// which threw away block ids, whatever Craft held that markdown cannot
    /// express, and the pad's position among pinned blocks — a document torn
    /// down and rebuilt over a state we merely could not attribute, which is
    /// `never-resolve-a-decode-failure-by-writing` from the other side
    /// (ccp-hu51). Its doc comment called this "churn on a rare path"; a
    /// remote add or delete arriving while the pad was dirty reached it
    /// every time.
    ///
    /// Pairing by order is still a guess — that is what misaligned means —
    /// but it is the guess that costs least when it is wrong, and the fetch
    /// that follows the push puts the base back in step. Pinned blocks are
    /// never written or deleted, and only anchor; slices carrying tags the
    /// pad cannot render are never posted as new blocks, so an edited pinned
    /// block cannot duplicate itself as an insert while the original stays
    /// (ccp-occ revert-guard).
    private static func realign(base: PadSyncBase, slices: [String]) -> BlockPushPlan {
        let agreed = writable(base.localSlices)
        let current = writable(slices)
        var plan = BlockPushPlan()
        /// Writable blocks paired so far — the cursor into both slice lists.
        var paired = 0
        // The last block still standing after this round: what a leftover
        // slice lands behind, so new text joins the end of the pad's own run
        // rather than the end of the document.
        var anchor: String?
        for block in base.blocks {
            guard block.isWritable else {
                anchor = block.id
                continue
            }
            guard paired < current.count else {
                plan.deletes.append(block.id)
                continue
            }
            // What the slice is measured against: our own recorded text for
            // that position while we still have it, which keeps the question
            // "did the pad change?" inside one dialect. Comparing against
            // Craft's markdown instead is ccp-c2x5 — it reads every block
            // Craft respelled as edited, so one keystroke anywhere would PUT
            // our stale spelling over every other block in the pad. Past the
            // record there is nothing but Craft's own text to compare with,
            // and a needless PUT is what having no record costs.
            let held = paired < agreed.count ? agreed[paired] : block.markdown
            if current[paired] != held {
                plan.updates.append(BlockUpdate(id: block.id, markdown: current[paired]))
            }
            paired += 1
            anchor = block.id
        }
        plan.append(inserts: Array(current.dropFirst(paired)), after: anchor)
        return plan
    }

    /// The markdown a push may write. A slice carrying tags the pad cannot
    /// render belongs to Craft, and is counted out of both sides so the two
    /// lists stay in step.
    private static func writable(_ markdowns: [String]) -> [String] {
        markdowns.filter { !CraftBlockPolicy.isUnwritable(markdown: $0) }
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
