// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// One conflict the pull stashed into Craft instead of overwriting: when it
/// happened (the server clock that dated the stash heading) and the local
/// text it preserved. The stash block ids pin the sidecar apart from this —
/// unpinning them would re-echo the copy into the pad — so the record is what
/// the conflicts popover lists, while the ids stay a sync concern only.
///
/// Records are newest-first per pad and capped; dismissing forgets the record
/// while the Craft-side copy (and its pins) stays where it is.
public struct ConflictRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date?
    public var slices: [String]

    public init(id: UUID = UUID(), date: Date?, slices: [String]) {
        self.id = id
        self.date = date
        self.slices = slices
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case slices
    }
}
