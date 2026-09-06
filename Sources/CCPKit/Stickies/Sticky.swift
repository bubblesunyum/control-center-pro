// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// One panel-pinned sticky: Markdown text, a paper colour, and a position in
/// `.panel` coordinate space. Draw order is array order — a sticky never
/// changes its depth, so there is no z-index to store.
///
/// Positions are plain x/y rather than a geometry type: this is persisted
/// data, and what survives a relaunch is two numbers, not a framework value.
/// The on-disk keys are pinned — renaming one orphans every saved sticky.
public struct Sticky: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var color: StickyColor
    public var x: Double
    public var y: Double
    public var isArchived: Bool

    public init(
        id: UUID = UUID(),
        text: String = "",
        color: StickyColor = .yellow,
        x: Double = 0,
        y: Double = 0,
        isArchived: Bool = false
    ) {
        self.id = id
        self.text = text
        self.color = color
        self.x = x
        self.y = y
        self.isArchived = isArchived
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, color, x, y, isArchived
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Every field past the id tolerates absence: an older file, or one
        // hand-edited half, still opens rather than costing the desk.
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        color = try container.decodeIfPresent(StickyColor.self, forKey: .color) ?? .yellow
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }

    /// What names this in the restore menu: the first line, or the fallback
    /// when the note is empty. A heading's markers are formatting, not title.
    public var displayTitle: String {
        let first = text.split(separator: "\n", maxSplits: 1).first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let unmarked = first.replacingOccurrences(
            of: "^#+\\s*",
            with: "",
            options: .regularExpression
        )
        return unmarked.isEmpty ? "New Sticky" : String(unmarked.prefix(40))
    }

    func movedTo(x: Double, y: Double) -> Sticky {
        var copy = self
        copy.x = x
        copy.y = y
        return copy
    }
}

/// The paper the sticky is drawn on. Names only — the fills live in CCPUI's
/// palette, next to every other colour literal.
public enum StickyColor: String, Codable, CaseIterable, Sendable {
    case yellow, pink, blue, green, purple, orange
}
