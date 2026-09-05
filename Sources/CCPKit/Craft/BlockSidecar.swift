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
        let oldPrints = entries.map(\.fingerprint)
        let newPrints = slices.map { Self.fingerprint($0.markdown) }
        let script = newPrints.difference(from: oldPrints)

        // Removal offsets index the sidecar, insertion offsets the slices.
        var removals: [(offset: Int, entry: BlockSidecarEntry)] = []
        var insertions: [(offset: Int, slice: CraftBlockSlice)] = []
        for change in script {
            switch change {
            case .remove(let offset, _, _):
                removals.append((offset, entries[offset]))
            case .insert(let offset, _, _):
                insertions.append((offset, slices[offset]))
            }
        }
        removals.sort { $0.offset < $1.offset }
        insertions.sort { $0.offset < $1.offset }

        // Same-offset pairs are in-place edits. Updated blocks stay anchors:
        // an insert after an edited block must follow the edited block's id,
        // not the survivor before it.
        var updates: [BlockUpdate] = []
        var deletes: [String] = []
        var editedIDs: [Int: String] = [:]
        var pendingInserts = insertions
        for removal in removals {
            if let match = pendingInserts.firstIndex(where: { $0.offset == removal.offset }) {
                let insertion = pendingInserts.remove(at: match)
                editedIDs[insertion.offset] = removal.entry.id
                if removal.entry.isWritable {
                    updates.append(BlockUpdate(id: removal.entry.id, markdown: insertion.slice.markdown))
                }
            } else if removal.entry.isWritable {
                deletes.append(removal.entry.id)
            }
        }

        // Anchor each insert after its nearest surviving predecessor.
        let removedOffsets = Set(removals.map(\.offset))
        let insertedOffsets = Set(insertions.map(\.offset))
        let survivingOld = entries.indices.filter { !removedOffsets.contains($0) }
        let survivingNew = slices.indices.filter { !insertedOffsets.contains($0) }
        var idForSlice: [Int: String] = [:]
        for (old, new) in zip(survivingOld, survivingNew) {
            idForSlice[new] = entries[old].id
        }
        for (new, id) in editedIDs {
            idForSlice[new] = id
        }
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
}
