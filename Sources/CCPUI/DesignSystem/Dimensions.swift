// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// Every gap and inset on the panel, as multiples of one 8pt unit.
///
/// A surface using 9, 12, 14 and 18 as gaps is four words for one idea, and the
/// eye tests every difference before discarding it. Reach for a step; a raw
/// number is a decision to justify.
public enum Space {
    public static let quarter: CGFloat = 2
    public static let half: CGFloat = 4
    public static let one: CGFloat = 8
    public static let oneHalf: CGFloat = 12
    public static let two: CGFloat = 16
    public static let three: CGFloat = 24
}

/// The width of the glass vocabulary's lines.
public enum Stroke {
    /// The hairline around a card. One point, not one pixel — on a Retina
    /// display a 1px line is thinner than the system draws its own.
    public static let hairline: CGFloat = 1
}

/// The panel and its cards are a nested pair of rounded rectangles: the card
/// radius sits visibly inside the panel's rather than splitting the difference
/// with it.
public enum Radius {
    public static let card: CGFloat = 16
    public static let panel: CGFloat = 24
    /// Controls that sit inside a card — a toggle tile, a segmented row.
    public static let control: CGFloat = 10
    /// Small readouts inside a card, e.g. the sparkline container.
    public static let sparkline: CGFloat = 6
    /// Small image thumbnail in clipboard rows.
    static let thumbnail: CGFloat = 4
}

/// How big the shell's boxes are.
///
/// A lane is a fixed width so the panel's growth is countable — one more lane
/// is one more column, not a reflow — and a widget's height comes from the size
/// it declares. `WidgetSize` names the intent; the points belong here.
public enum Layout {
    /// Height of the scrollable clipboard list — 50% taller than the original 220 to show ~7 rows.
    static let clipboardListHeight: CGFloat = 330
    /// Size of a row's leading icon and trailing menu button.
    static let rowActionSize: CGFloat = 22
    /// Thumbnail shown on the trailing edge of an image clipboard row.
    static let clipboardThumbnailWidth: CGFloat = 44
    static let clipboardThumbnailHeight: CGFloat = 32
    /// Larger preview used in the context menu for an image entry.
    static let clipboardPreviewWidth: CGFloat = 220
    static let clipboardPreviewHeight: CGFloat = 160
    /// Max width of the full-text preview at the bottom of the clipboard context menu.
    static let clipboardMenuMaxWidth: CGFloat = 320
    public static let laneWidth: CGFloat = 240
    /// How far the panel sits from the screen's top-right corner.
    public static let panelInset: CGFloat = Space.one

    /// How many lanes a display this wide can actually show.
    ///
    /// The panel is anchored top-right and does not scroll, so a lane past
    /// this is a column hanging off the left edge of the screen with nothing
    /// to say it is there. Edit mode refuses the drop that would make one
    /// rather than letting the arrangement grow somewhere the user can't see
    /// it (ccp-p6g).
    public static func laneCapacity(inWidth width: CGFloat) -> Int {
        let usable = width - panelInset * 2 - Space.oneHalf * 2
        return max(1, Int((usable + Space.oneHalf) / (laneWidth + Space.oneHalf)))
    }
}

public extension WidgetSize {
    /// The height a widget of this size asks for. A widget whose content needs
    /// more gets it — the panel is sized from what it actually holds — so this
    /// is the floor that keeps a lane of small widgets from looking ragged.
    var height: CGFloat {
        switch self {
        case .compact: 64
        case .regular: 132
        case .tall: 232
        }
    }
}

public extension Layout {
    /// Height of the miniature graphs in the System Stats card.
    static let sparklineHeight: CGFloat = Space.three + Space.half // 28
}
