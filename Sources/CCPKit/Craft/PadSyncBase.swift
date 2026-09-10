// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// One block as Craft held it at the last agreement.
public struct BaseBlock: Codable, Equatable, Sendable {
    public var id: String
    /// Craft's markdown, verbatim — not a hash. A hash cannot be merged, and
    /// the text is what makes a disagreement readable when one happens.
    public var markdown: String
    /// False for blocks Craft will not take back (`CraftBlockPolicy`). The
    /// push routes around these instead of deleting what it cannot write.
    public var isWritable: Bool

    // Pinned: the base is persisted, so renaming a property must never
    // rename the stored key (a-codable-rename-is-a-data-migration).
    private enum CodingKeys: String, CodingKey {
        case id, markdown
        case isWritable = "writable"
    }

    public init(id: String, markdown: String, isWritable: Bool = true) {
        self.id = id
        self.markdown = markdown
        self.isWritable = isWritable
    }
}

/// The two texts that were last in agreement for one pad — ours and Craft's.
///
/// This is the whole of the sync's state, and the reason it can be trusted:
/// "did the panel change?" and "did Craft change?" are string comparisons,
/// each made **in its own dialect**, against bytes that were observed rather
/// than derived. Nothing is inferred from a diff, so nothing can drift.
///
/// The pair is expected to be asymmetric. Craft normalises on write
/// (`craft-normalises-markdown-on-write`) and splits blocks we send whole, so
/// `localText` and the joined `blocks` are routinely different strings for the
/// same content. Recording that asymmetry is what makes it free: it is
/// established once, at the moment of agreement, and never re-derived.
///
/// The predecessor (`BlockSidecar`, ccp-2zi.5) stored one hash per block and
/// asked the push diff whether the pad was clean. That compared our markdown
/// against hashes of Craft's, so any respelled block read as a permanent local
/// edit and every remote move became a conflict (ccp-c2x5).
public struct PadSyncBase: Codable, Equatable, Sendable {
    /// The exact pad text at the last agreement — our dialect.
    public var localText: String
    /// What Craft held at that same moment, in order — Craft's dialect.
    public var blocks: [BaseBlock]

    private enum CodingKeys: String, CodingKey {
        case localText = "local"
        case blocks
    }

    public init(localText: String = "", blocks: [BaseBlock] = []) {
        self.localText = localText
        self.blocks = blocks
    }

    public var isEmpty: Bool { localText.isEmpty && blocks.isEmpty }

    /// Craft's side of the base as one pad-shaped string.
    public var remoteText: String { CraftPull.join(blocks.map(\.markdown)) }

    /// Seed from a fetch: what Craft holds now becomes what we agree it holds.
    /// `excluding` drops the legacy conflict copies a previous version posted,
    /// so they stay out of the pad without being deleted from Craft.
    ///
    /// Blocks Craft carries no markdown for — an image, an embed — are left
    /// out entirely. The push only ever names ids the base holds, so leaving
    /// them out is what guarantees they are never rewritten or deleted:
    /// what we do not model, we do not touch.
    public static func remote(_ blocks: [FetchedBlock],
                              excluding stashIDs: Set<String> = []) -> [BaseBlock] {
        blocks.compactMap { block in
            guard let markdown = block.markdown, !stashIDs.contains(block.id) else { return nil }
            return BaseBlock(id: block.id, markdown: markdown,
                             isWritable: !CraftBlockPolicy.isUnwritable(markdown: markdown))
        }
    }

    /// Whether Craft holds something other than what we last agreed it held.
    /// Both id and text, so a block replaced in place still reads as moved.
    public static func remoteMoved(_ fetched: [BaseBlock], from base: [BaseBlock]) -> Bool {
        fetched.map { "\($0.id)\n\($0.markdown)" } != base.map { "\($0.id)\n\($0.markdown)" }
    }

    /// The pad text as the push cuts it — the base's own slices, our dialect.
    /// Paired by index with `blocks` when the counts agree; when Craft split
    /// something they do not, and every caller degrades rather than guessing
    /// an alignment.
    public var localSlices: [String] {
        CraftBlockSplitter.slices(in: localText).map(\.markdown)
    }

    /// True when our slices and Craft's blocks stand one-to-one, which is
    /// what lets a local slice index name a Craft block id.
    public var isAligned: Bool { localSlices.count == blocks.count }
}
