// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Merge two sets of edits made to the same block sequence.
///
/// Both sides are diffed against the base they actually started from, so
/// edits touching different blocks combine silently — the common case by far,
/// since the panel and Craft are usually being used on different parts of a
/// note. Only blocks *both* sides changed are a real disagreement, and those
/// keep the panel's version: it is the text the user was looking at most
/// recently, and Craft's version is kept in the pad's history regardless.
///
/// This is possible only because there is a real base to merge against
/// (`PadSyncBase`). Without one, every simultaneous edit had to be called a
/// conflict, which is what made conflicts routine instead of rare (ccp-c2x5).
public enum ThreeWayMerge {
    public struct Result: Equatable, Sendable {
        public var merged: [String]
        /// True when at least one block was changed differently on both
        /// sides. Drives the history snapshot and the conflicts popover —
        /// never a write to Craft.
        public var hadConflict: Bool
    }

    /// Merge `ours` and `theirs`, both derived from `base`.
    ///
    /// `theirBase` is the same content in Craft's dialect, when the two are
    /// known to stand one-to-one (`PadSyncBase.isAligned`). Craft respells
    /// what it stores, so diffing its blocks against *our* base would read
    /// every respelled block as an edit Craft made; diffing them against
    /// Craft's own base sees only what someone actually changed there. Pass
    /// nil when the two do not align and accept the false positives — they
    /// cost a spurious history snapshot, never text.
    ///
    /// `pinned` names base indices Craft owns (ccp-occ): the pad can never
    /// win those, so ours edits there are dropped and theirs stands — without
    /// raising a conflict, since there was never anything to save. The
    /// replacing pull snapshots the discarded text into history regardless.
    ///
    /// Always produces a usable result: there is no blocked or half-applied
    /// state, and nothing is left for the user to resolve by hand.
    public static func merge(base: [String], ours: [String], theirs: [String],
                             theirBase: [String]? = nil,
                             pinned: Set<Int> = []) -> Result {
        let mine = Alignment(base: base, side: ours)
        let yours = Alignment(base: theirBase ?? base, side: theirs)
        var merged: [String] = []
        var hadConflict = false

        for index in base.indices {
            merged += mine.insertsBefore[index] ?? []
            merged += yours.insertsBefore[index] ?? []
            let isPinned = pinned.contains(index)
            switch (mine.replacements[index], yours.replacements[index]) {
            case (nil, nil):
                merged.append(base[index])
            case (let ourChange?, nil):
                // Pinned and only we touched it: our edit can never be
                // written back, so the base stands and the push later
                // restores the pad rather than duplicating it.
                if isPinned {
                    merged.append(base[index])
                } else {
                    merged += ourChange
                }
            case (nil, let theirChange?):
                merged += theirChange
            case (let ourChange?, let theirChange?):
                // Identical edits are agreement, not conflict: two people
                // fixing the same typo must not raise one.
                if isPinned {
                    merged += theirChange
                } else {
                    if ourChange != theirChange { hadConflict = true }
                    merged += ourChange
                }
            }
        }
        merged += mine.insertsBefore[base.count] ?? []
        merged += yours.insertsBefore[base.count] ?? []
        return Result(merged: merged, hadConflict: hadConflict)
    }
}

/// What one side did to the base, expressed against **base** positions.
///
/// Shared with the push plan (`BlockPushPlan.plan`), which asks the same
/// question of the pad — what happened to each block since the base — and
/// then names the answer's Craft ids.
///
/// `CollectionDifference` indexes its insertions into the new sequence, which
/// on its own says nothing about where they landed in the base. Pairing the
/// surviving elements of both sequences recovers that: everything between two
/// survivors on the base side was replaced by everything between the same two
/// survivors on the new side.
struct Alignment {
    /// Base index to the blocks that now stand in its place; empty for a
    /// straight delete. Absent means untouched.
    private(set) var replacements: [Int: [String]] = [:]
    /// Blocks added in front of a base index, touching nothing there. Keyed
    /// by `base.count` for a tail append.
    private(set) var insertsBefore: [Int: [String]] = [:]

    init(base: [String], side: [String]) {
        let difference = side.difference(from: base)
        guard !difference.isEmpty else { return }
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Total by construction: both sequences lose exactly their own
        // changes, so the survivors count the same on each side.
        let survivingBase = base.indices.filter { !removed.contains($0) } + [base.count]
        let survivingSide = side.indices.filter { !inserted.contains($0) } + [side.count]

        var previousBase = -1
        var previousSide = -1
        for (baseIndex, sideIndex) in zip(survivingBase, survivingSide) {
            let gone = (previousBase + 1)..<baseIndex
            let arrived = Array(side[(previousSide + 1)..<sideIndex])
            record(gone: gone, arrived: arrived, before: baseIndex)
            previousBase = baseIndex
            previousSide = sideIndex
        }
    }

    /// A run of base blocks that went away, and the run that arrived in the
    /// same gap. With nothing gone the arrivals are a pure insertion in front
    /// of `before`; otherwise they replace the first departed block and the
    /// rest of the run deletes.
    private mutating func record(gone: Range<Int>, arrived: [String], before: Int) {
        guard let first = gone.first else {
            if !arrived.isEmpty { insertsBefore[before] = arrived }
            return
        }
        replacements[first] = arrived
        for index in gone.dropFirst() { replacements[index] = [] }
    }
}
