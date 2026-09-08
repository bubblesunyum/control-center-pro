// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// One panel-pinned sticky: Markdown text, a paper colour, a position and a
/// size in `.panel` coordinate space. Draw order is array order — a sticky
/// never changes its depth, so there is no z-index to store.
///
/// Positions are plain x/y rather than a geometry type: this is persisted
/// data, and what survives a relaunch is two numbers, not a framework value.
/// The on-disk keys are pinned — renaming one orphans every saved sticky.
public struct Sticky: Codable, Equatable, Identifiable, Sendable {
    /// What a sticky measures when it has never been resized, and what notes
    /// written before size existed decode to. The whole card, the paper
    /// border on every side included — so the paper a new note offers is this
    /// less twice `StickyCard.edgeWidth`.
    public static let defaultWidth: Double = 288
    public static let defaultHeight: Double = 240
    /// The smallest a resize may leave behind — below this the text is a
    /// slit, not a note. The floor is the card, paper border included, so
    /// the height leaves roughly two lines of paper behind it.
    public static let minWidth: Double = 136
    public static let minHeight: Double = 72

    public var id: UUID
    public var text: String
    public var color: StickyColor
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var isArchived: Bool

    public init(
        id: UUID = UUID(),
        text: String = "",
        color: StickyColor = .yellow,
        x: Double = 0,
        y: Double = 0,
        width: Double = defaultWidth,
        height: Double = defaultHeight,
        isArchived: Bool = false
    ) {
        self.id = id
        self.text = text
        self.color = color
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isArchived = isArchived
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, color, x, y, width, height, isArchived
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
        // Lenient where the older keys are strict: a mistyped size must fall
        // back to the default, never cost the note — and anything that loads
        // still honours the minimum, so a hand-edited zero can't strand an
        // ungrabbable frame on the desk.
        width = max(
            (try? container.decodeIfPresent(Double.self, forKey: .width)) ?? Self.defaultWidth,
            Self.minWidth
        )
        height = max(
            (try? container.decodeIfPresent(Double.self, forKey: .height)) ?? Self.defaultHeight,
            Self.minHeight
        )
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

    /// The one resize rule: every resize path lands here, so the minimum
    /// holds wherever the size came from — the grip, an accessibility step,
    /// or a hand-edited file on load.
    public func resizedTo(width: Double, height: Double) -> Sticky {
        var copy = self
        copy.width = max(width, Self.minWidth)
        copy.height = max(height, Self.minHeight)
        return copy
    }
}

/// The paper the sticky is drawn on. Names only — the fills live in CCPUI's
/// palette, next to every other colour literal.
public enum StickyColor: String, Codable, CaseIterable, Sendable {
    case yellow, pink, blue, green, purple, orange
}
