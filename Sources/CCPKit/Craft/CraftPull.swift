// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// What a pull decided for one pad. Pure data — the adapter spends it.
public enum PullDecision: Equatable, Sendable {
    /// Remote and local already agree: record the clock, clear the pad's
    /// dirty bit, touch nothing else. Also covers our own push's mtime bump,
    /// which moves no text and must never stash.
    case converged
    /// The pad is clean: replace its text and sidecar from the fetch.
    case adopt(text: String, sidecar: BlockSidecar)
    /// Both sides moved: POST `stash` to Craft under `heading`, then adopt.
    case conflict(heading: String, stash: [String], text: String, sidecar: BlockSidecar)
    /// Local leads and remote did not move, or there is nothing on either
    /// side yet: change nothing.
    case skip
}

/// The pull half of two-way sync: join a fetch into pad text, seed the
/// sidecar from it, and decide which of adopt/conflict/skip a pad gets.
/// ccp-2zi.6 spends this; ccp-2zi.5 owns the push plan.
///
/// Moved detection is an exact signature compare — remote (id, fingerprint)
/// pairs against the sidecar — not timestamps. Our own pushes bump
/// `lastModifiedAt` without moving text, so any clock compare reads our own
/// echo as a remote move; the signature cannot. The server clock still dates
/// the conflict stash and records the sync point, per the epic.
public enum CraftPull {
    /// Join fetched markdown into pad text. Hard breaks throughout — the same
    /// boundary the monitor mints (ccp-qzzt), so pulled text renders tight
    /// and resplits identically. Lists need no special case: trailing spaces
    /// do not disturb item recognition, and the splitter descends list nodes
    /// into per-item slices either way.
    public static func join(_ markdowns: [String]) -> String {
        markdowns.joined(separator: "  \n")
    }

    /// Seed the sidecar from a fetch, in document order. Every block pins —
    /// including markdown-less ones and the ones the policy calls unwritable
    /// — so the push routes around what it must never write instead of
    /// deleting it. Markdown-less entries fingerprint the empty string on
    /// both sides of the compare, so they read stable, never changed.
    public static func seed(_ blocks: [FetchedBlock]) -> BlockSidecar {
        BlockSidecar(entries: blocks.map { block in
            BlockSidecarEntry(id: block.id,
                              fingerprint: BlockSidecar.fingerprint(block.markdown ?? ""),
                              isWritable: block.markdown != nil
                                && !CraftBlockPolicy.isUnwritable(markdown: block.markdown!))
        })
    }

    /// Decide for one pad. Confirmation is the push plan, never the dirty
    /// bit: the bit is in-memory (a crash forgets it) and no-op pushes clear
    /// it, so neither proves Craft holds the local text. `stashIDs` are the
    /// conflict copies this pad posted: they pin the sidecar and stay out of
    /// the pad. They are tracked apart from the sidecar's policy flags on
    /// purpose — a policy-unwritable block the user fixes in Craft must rejoin
    /// the pad, while a stash copy must never come back.
    public static func decide(local: String, sidecar: BlockSidecar,
                              remote: [FetchedBlock],
                              stashIDs: Set<String> = []) -> PullDecision {
        let texts = remote.filter { !stashIDs.contains($0.id) }.compactMap(\.markdown)
        let text = join(texts)
        var seeded = seed(remote)
        for index in seeded.entries.indices where stashIDs.contains(seeded.entries[index].id) {
            seeded.entries[index].isWritable = false
        }
        let moved = signature(remote) != signature(sidecar)
        guard moved else {
            // Remote matches the last confirmed state: local differences are
            // ours, and the push owns them — except exact agreement, which
            // converges (and clears a stale dirty bit).
            return text == local ? .converged : .skip
        }
        let slices = CraftBlockSplitter.slices(in: local)
        guard !sidecar.pushPlan(for: slices).isEmpty else {
            return .adopt(text: text, sidecar: seeded)
        }
        let stash = slices.map(\.markdown)
        guard !stash.isEmpty else {
            // The pad was cleared while Craft moved: empty text over a
            // non-empty sidecar is a delete the push has not confirmed, not
            // "nothing to lose". Adopting would wipe the clear and its dirty
            // bit — skip so the push deletes what the sidecar still holds.
            return .skip
        }
        // The stash carries the whole local text, confirmed base included —
        // deduping it is polish for a path that must first of all lose
        // nothing.
        return .conflict(heading: "# Conflicted copy", stash: stash, text: text, sidecar: seeded)
    }

    /// The remote's signature: one (id, fingerprint) pair per block, in
    /// order. Compared against the sidecar's entries as stored. Joined
    /// strings rather than tuples — tuples never conform to Equatable, so a
    /// pair array cannot compare directly.
    private static func signature(_ remote: [FetchedBlock]) -> [String] {
        remote.map { "\($0.id)\n\(BlockSidecar.fingerprint($0.markdown ?? ""))" }
    }

    private static func signature(_ sidecar: BlockSidecar) -> [String] {
        sidecar.entries.map { "\($0.id)\n\($0.fingerprint)" }
    }
}
