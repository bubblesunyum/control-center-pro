// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CryptoKit
import Foundation

/// Which Craft block a slice IS, and what Craft last held for it.
///
/// The pad carries one sidecar per note, stored beside it and never shown.
/// A push diffs fresh slices against this list; a pull seeds it. The ids are
/// what keep Craft's block links, backlinks and comments stable across
/// syncs — without them every push would degenerate into delete-and-repost.
public struct BlockSidecarEntry: Codable, Equatable, Sendable {
    /// The Craft block id.
    public var id: String
    /// SHA-256 over Craft's markdown for the block. Craft's form, never
    /// ours: ours is not a fixed point — Craft normalises on write, so a pad
    /// holding our spelling would read as changed on every sync and the loop
    /// would never quiet.
    public var fingerprint: String
    /// False for blocks Craft will not take back. The diff pins these: they
    /// never produce an update or a delete, whatever the text around them
    /// does. Set by the pull side from `CraftBlockPolicy`.
    public var isWritable: Bool

    // Pinned: the sidecar is persisted, so renaming a property must never
    // rename the stored key.
    private enum CodingKeys: String, CodingKey {
        case id, fingerprint
        case isWritable = "writable"
    }

    public init(id: String, fingerprint: String, isWritable: Bool = true) {
        self.id = id
        self.fingerprint = fingerprint
        self.isWritable = isWritable
    }
}

/// One changed block: new markdown PUT over the id the sidecar already holds.
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
    public var updates: [BlockUpdate]
    public var inserts: [BlockInsert]
    public var deletes: [String]

    public var isEmpty: Bool {
        updates.isEmpty && inserts.isEmpty && deletes.isEmpty
    }
}

/// The block-id sidecar: the join between the pad's one markdown string and
/// Craft's addressable blocks. ccp-2zi.5 spends the push plan, ccp-2zi.6
/// seeds the entries from a pull; this type is the contract between them.
public struct BlockSidecar: Codable, Equatable, Sendable {
    public var entries: [BlockSidecarEntry]

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    public init(entries: [BlockSidecarEntry] = []) {
        self.entries = entries
    }

    /// The fingerprint for a markdown string. Stable across launches (a
    /// seeded hasher is not — it must never be persisted).
    public static func fingerprint(_ markdown: String) -> String {
        let digest = SHA256.hash(data: Data(markdown.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Diff fresh slices against the sidecar. The algorithm is the stdlib's
    /// `CollectionDifference` over fingerprints — no hand-rolled LCS. A
    /// remove and an insert at the same offset read as an in-place edit
    /// (one PUT); anything else is a delete, an insert, or both.
    ///
    /// Deliberately conservative: an edit beside an insertion churns that
    /// block through delete-and-post rather than risk PUTting one slice's
    /// text into another slice's id. Text always lands correctly; identity
    /// is never gambled. Duplicate slices pairing arbitrarily on a reorder
    /// is the known residual (ccp-3td) — churn, not corruption.
    public func pushPlan(for slices: [CraftBlockSlice]) -> BlockPushPlan {
        let script = pushScript(for: slices)

        var updates: [BlockUpdate] = []
        var deletes: [String] = []
        var pendingInserts = script.insertions
        for removal in script.removals {
            if let match = pendingInserts.firstIndex(where: { $0.offset == removal.offset }) {
                let insertion = pendingInserts.remove(at: match)
                if removal.entry.isWritable {
                    updates.append(BlockUpdate(id: removal.entry.id, markdown: insertion.slice.markdown))
                }
            } else if removal.entry.isWritable {
                deletes.append(removal.entry.id)
            }
        }

        // Anchor each insert after its nearest surviving predecessor. Updated
        // blocks stay anchors: an insert after an edited block must follow
        // the edited block's id, not the survivor before it.
        let idForSlice = script.anchorIDs(entries: entries, sliceCount: slices.count)
        var inserts: [BlockInsert] = []
        for insertion in pendingInserts {
            var anchor: String?
            var predecessor = insertion.offset - 1
            while predecessor >= 0 {
                if let id = idForSlice[predecessor] {
                    anchor = id
                    break
                }
                predecessor -= 1
            }
            inserts.append(BlockInsert(afterID: anchor, markdown: insertion.slice.markdown))
        }

        return BlockPushPlan(updates: updates, inserts: inserts, deletes: deletes)
    }

    /// Rebuild the sidecar from what the push actually confirmed, and derive
    /// the write-back. Only 2xx-confirmed units are recorded — a half-applied
    /// diff must not be stored as applied, so whatever is missing from the
    /// echoes simply diffs again next round.
    ///
    /// - `putEcho` pairs back to updates by id; an update with no echo keeps
    ///   its old entry and is retried.
    /// - `postEchoByInsert` maps the diff's unpaired-insertion index (which is
    ///   the plan's insert order) to that insert's echo, in request order. A
    ///   split shows as several items under one index; the adapter already
    ///   contained splits to their own anchor group, so misattribution
    ///   cannot cross groups. A missing index stays absent and retries.
    /// - `deletesConfirmed` gates removals; a failed DELETE re-deletes.
    ///
    /// Entries come out in pad order. Pinned (read-only) entries keep their
    /// old pairing whatever the echoes say.
    public func applyingPush(text: String,
                             slices: [CraftBlockSlice],
                             putEcho: [CraftBlock],
                             postEchoByInsert: [Int: [CraftBlock]],
                             deletesConfirmed: Bool) -> (sidecar: BlockSidecar, writeBack: [CraftWriteBack]) {
        let script = pushScript(for: slices)
        let putByID = Dictionary(putEcho.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        let unpaired = script.insertions.filter { insertion in
            script.pairedByNew[insertion.offset] == nil
        }
        // Plan-insert index to slice offset, in the shared order.
        var insertEchoes: [Int: [CraftBlock]] = [:]
        for (planIndex, insertion) in unpaired.enumerated() {
            if let echoes = postEchoByInsert[planIndex], !echoes.isEmpty {
                insertEchoes[insertion.offset] = echoes
            }
        }

        var rebuilt: [BlockSidecarEntry] = []
        var writeBack: [CraftWriteBack] = []
        for index in slices.indices {
            pairUpdate(&rebuilt, &writeBack, script: script, slices: slices,
                       putByID: putByID, index: index)
            pairInsert(&rebuilt, insertEchoes: insertEchoes, index: index)
            carrySurvivor(&rebuilt, script: script, slices: slices, index: index,
                          inserted: insertEchoes[index] != nil)
            // Unconfirmed inserts stay absent so they retry, and confirmed
            // deletes simply leave no entry.
        }
        writeBack.append(contentsOf: insertRunWriteBacks(
            text: text, slices: slices, script: script, insertEchoes: insertEchoes))
        // A failed DELETE must restore its entries or the next diff forgets
        // they exist and they orphan. Pinned entries restore unconditionally:
        // they never rode the DELETE request, so its outcome says nothing
        // about them. Gone slices have no pad position, so restored entries
        // append: order shifts, which the next diff absorbs as churn — and
        // the next successful push rebuilds pad order exactly.
        let pairedOld = Set(script.paired.map(\.old))
        for removal in script.removals where !pairedOld.contains(removal.offset) {
            if !deletesConfirmed || !removal.entry.isWritable {
                rebuilt.append(removal.entry)
            }
        }
        return (BlockSidecar(entries: rebuilt), writeBack)
    }

    private func pairUpdate(_ rebuilt: inout [BlockSidecarEntry],
                            _ writeBack: inout [CraftWriteBack],
                            script: PushScript, slices: [CraftBlockSlice],
                            putByID: [String: CraftBlock],
                            index: Int) {
        guard let oldOffset = script.pairedByNew[index] else { return }
        let old = entries[oldOffset]
        guard let echo = putByID[old.id], old.isWritable else {
            // No echo (PUT failed for this block) or pinned: keep the old
            // pairing. A failed block diffs again next round; a pinned one
            // reads changed-and-dropped, stably.
            rebuilt.append(old)
            return
        }
        rebuilt.append(BlockSidecarEntry(id: old.id,
                                         fingerprint: Self.fingerprint(echo.markdown)))
        if echo.markdown != slices[index].markdown {
            // Trimmed range: the raw span's trailing line break is not ours.
            let range = NSRange(location: slices[index].range.location,
                                length: (slices[index].markdown as NSString).length)
            writeBack.append(CraftWriteBack(range: range,
                                            prior: slices[index].markdown,
                                            markdown: echo.markdown))
        }
    }

    private func pairInsert(_ rebuilt: inout [BlockSidecarEntry],
                            insertEchoes: [Int: [CraftBlock]], index: Int) {
        guard let echoes = insertEchoes[index] else { return }
        for echo in echoes {
            rebuilt.append(BlockSidecarEntry(id: echo.id,
                                             fingerprint: Self.fingerprint(echo.markdown)))
        }
    }

    private func carrySurvivor(_ rebuilt: inout [BlockSidecarEntry],
                               script: PushScript, slices: [CraftBlockSlice], index: Int,
                               inserted: Bool) {
        guard script.pairedByNew[index] == nil, !inserted else { return }
        // Survivors align in order; the zip is total (a valid script drops
        // as many as it adds), so a miss here is unreachable — and skipping
        // is the safe shape for it, never a fabricated id.
        let survivingOld = entries.indices.filter { !script.removedOffsets.contains($0) }
        let survivingNew = slices.indices.filter { !script.insertedOffsets.contains($0) }
        for (old, new) in zip(survivingOld, survivingNew) where new == index {
            rebuilt.append(entries[old])
        }
    }

    /// Write-back over maximal runs of echoed inserts. The replacement
    /// interleaves the echoes with the pad's OWN separators between the
    /// run's slices — a tight list rejoins with single newlines, exactly as
    /// it was, so an unchanged push writes back nothing at all. Only within
    /// one slice (a server-side split) is "\n\n" assumed, which is the only
    /// split Craft has ever been observed to make.
    ///
    /// Run-level (not per-insert) because a split's boundaries are
    /// unknowable — joining per-insert groups could overwrite one slice with
    /// another's tail, while the run's values and order are exact whatever
    /// the boundaries were. A run is contiguous by construction, so its span
    /// never eats a survivor's text.
    private func insertRunWriteBacks(text: String,
                                     slices: [CraftBlockSlice],
                                     script: PushScript,
                                     insertEchoes: [Int: [CraftBlock]]) -> [CraftWriteBack] {
        let offsets = script.insertions.map(\.offset).filter { insertEchoes[$0] != nil }
        var runs: [[Int]] = []
        for offset in offsets {
            if let tail = runs.last?.last, tail + 1 == offset {
                runs[runs.count - 1].append(offset)
            } else {
                runs.append([offset])
            }
        }
        let ns = text as NSString
        var edits: [CraftWriteBack] = []
        for run in runs {
            guard let first = run.first, let last = run.last,
                  NSMaxRange(slices[last].range) <= ns.length else { continue }
            let echoes = run.flatMap { insertEchoes[$0] ?? [] }
            guard !echoes.isEmpty else { continue }
            // The span's tail is trimmed like a single slice's: the raw
            // range's trailing line break is a separator, not content.
            let tailTrimmed = (slices[last].markdown as NSString).length
            let end = slices[last].range.location + tailTrimmed
            guard end >= slices[first].range.location else { continue }
            var replacement = ""
            // Separators run from each slice's TRIMMED end: the raw range's
            // own trailing break belongs to the separator, not the content —
            // reading from the raw end would swallow one newline per slice
            // (a blank line lost, or a tight list blown open).
            var previousEnd = slices[first].range.location
            for (i, offset) in run.enumerated() {
                if i > 0 {
                    let gap = NSRange(location: previousEnd,
                                      length: slices[offset].range.location - previousEnd)
                    replacement += ns.substring(with: gap)
                }
                replacement += (insertEchoes[offset] ?? []).map(\.markdown).joined(separator: "\n\n")
                previousEnd = slices[offset].range.location
                    + (slices[offset].markdown as NSString).length
            }
            let span = NSRange(location: slices[first].range.location,
                               length: end - slices[first].range.location)
            let prior = ns.substring(with: span)
            if replacement != prior {
                edits.append(CraftWriteBack(range: span, prior: prior, markdown: replacement))
            }
        }
        return edits
    }
}

/// One write-back edit: Craft's canonical spelling over the pushed range.
/// Applied only when the pad still holds `prior` there — a user who kept
/// typing mid-flight wins over the echo.
public struct CraftWriteBack: Equatable, Sendable {
    public var range: NSRange
    public var prior: String
    public var markdown: String
}

/// The raw diff script: removals index the sidecar, insertions the slices.
/// Shared by the plan and the sidecar rebuild so the two can never disagree
/// about what paired with what.
private struct PushScript {
    var removals: [(offset: Int, entry: BlockSidecarEntry)]
    var insertions: [(offset: Int, slice: CraftBlockSlice)]
    /// Same-offset pairs: in-place edits, removal offset to insertion offset.
    var paired: [(old: Int, new: Int)]
    /// Precomputed once: edit offset to slice offset, removed offsets,
    /// inserted offsets.
    var pairedByNew: [Int: Int]
    var removedOffsets: Set<Int>
    var insertedOffsets: Set<Int>

    /// Slice index to Craft id for every slice that keeps one: survivors plus
    /// edited blocks (an insert after an edit anchors to the edit).
    func anchorIDs(entries: [BlockSidecarEntry], sliceCount: Int) -> [Int: String] {
        var ids: [Int: String] = [:]
        let survivingOld = entries.indices.filter { !removedOffsets.contains($0) }
        let survivingNew = (0..<sliceCount).filter { !insertedOffsets.contains($0) }
        for (old, new) in zip(survivingOld, survivingNew) {
            ids[new] = entries[old].id
        }
        for pair in paired {
            ids[pair.new] = entries[pair.old].id
        }
        return ids
    }
}

private extension BlockSidecar {
    func pushScript(for slices: [CraftBlockSlice]) -> PushScript {
        let oldPrints = entries.map(\.fingerprint)
        let newPrints = slices.map { Self.fingerprint($0.markdown) }
        let diff = newPrints.difference(from: oldPrints)
        var removals: [(offset: Int, entry: BlockSidecarEntry)] = []
        var insertions: [(offset: Int, slice: CraftBlockSlice)] = []
        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                removals.append((offset, entries[offset]))
            case .insert(let offset, _, _):
                insertions.append((offset, slices[offset]))
            }
        }
        removals.sort { $0.offset < $1.offset }
        insertions.sort { $0.offset < $1.offset }
        let insertOffsets = Set(insertions.map(\.offset))
        let paired = removals.map(\.offset).filter { insertOffsets.contains($0) }
            .map { offset in (old: offset, new: offset) }
        return PushScript(removals: removals, insertions: insertions, paired: paired,
                          pairedByNew: Dictionary(uniqueKeysWithValues: paired.map { ($0.new, $0.old) }),
                          removedOffsets: Set(removals.map(\.offset)),
                          insertedOffsets: insertOffsets)
    }
}
