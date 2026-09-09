// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Why a history snapshot was taken: what replaced the pad's text. The menu
/// shows the reason beside the date, so restoring reads as a choice rather
/// than a guess.
public enum SnapshotReason: String, Codable, Sendable {
    /// A pull adopted remote text over the local pad.
    case pull
    /// A conflict merge replaced the local side (already stashed to Craft).
    case conflict
    /// A history restore replaced the current text. Recorded first, so the
    /// menu stays safe to poke at.
    case preRestore
}

/// One pre-replacement copy of a pad's text (ccp-o3k): what the pad held
/// before a pull, a conflict merge, or a restore replaced it wholesale.
/// Full markdown, never a diff — pads are short-lived scratch text, so
/// copies are affordable and diffing would be premature. Bounded per pad;
/// restoring snapshots the current text first, so poking the menu never
/// loses work.
public struct PadSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date?
    public var reason: SnapshotReason
    public var markdown: String

    public init(id: UUID = UUID(), date: Date?, reason: SnapshotReason, markdown: String) {
        self.id = id
        self.date = date
        self.reason = reason
        self.markdown = markdown
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case reason
        case markdown
    }
}
