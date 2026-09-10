// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// A throwaway notes folder. UUID-scoped under /tmp, like the other
/// file-based tests; the OS reaps them, so tests never clean up after
/// themselves here.
func freshNotesDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ccp.notes.\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@testable import CCPKit

extension PadSyncBase {
    /// The agreement a pad reaches after a normal push: `local` is what the
    /// pad holds, `blocks` is what Craft made of it (defaulting to the same
    /// text, which is what an un-normalising fake echoes back), with ids
    /// `block-0`, `block-1`, … unless `ids` names them.
    static func fixture(_ local: String, blocks: [String]? = nil,
                        ids: [String]? = nil,
                        writable: Bool = true) -> PadSyncBase {
        let markdowns = blocks ?? CraftBlockSplitter.slices(in: local).map(\.markdown)
        return PadSyncBase(localText: local, blocks: markdowns.enumerated().map { index, markdown in
            BaseBlock(id: ids?[index] ?? "block-\(index)", markdown: markdown,
                      isWritable: writable)
        })
    }
}
