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
    /// The resize tick's weight. Heavier than a hairline on purpose, and held
    /// here rather than inline: the tick is a bare mark on glass with no
    /// surrounding chrome, so its legibility is the number.
    public static let resizeTick: CGFloat = 3.5
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

    /// How tall the note editor stands. Live-styled Markdown needs the
    /// room: at 148pt a heading and a short list filled the card, and a note you
    /// cannot see is a worse note than a plain-text one. Set here rather than on
    /// `WidgetSize.tall`, which the clipboard shares and which would leave dead
    /// glass under its own capped list.
    static let noteEditorHeight: CGFloat = 300

    /// The vertical rail of note tabs. Narrow enough to leave the note the
    /// larger half of a 300pt lane, wide enough that "Groceries" reads.
    static let noteTabRailWidth: CGFloat = 84
    /// One tab in that rail. Twelve of them plus the new-note row is the most
    /// there can ever be, and at this height they still fit beside the editor
    /// without the rail needing to scroll — which is what keeps the tab card
    /// a short fixed column.
    static let noteTabHeight: CGFloat = 24
    /// How far the note container tucks over the tab card's trailing edge: a
    /// small overlap, enough that the selected tab reads as flowing under the
    /// note rather than parked beside it. The rail's content clears this
    /// strip, so no control ever sits half under the note.
    static let noteTuck: CGFloat = Space.one

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
    /// The resize grip's touch box: a 44pt square in the card's corner. The
    /// platform minimum for a touch target, and deliberately larger than the
    /// white arc drawn inside it — the finger lands near the edge, not on a
    /// line. What the panel hit-tests against (see `GripFramePreference`).
    static let resizeTouchTarget: CGFloat = 44
    /// How far the grip's touch area overshoots its drawn box, on every side.
    /// Near-misses on the corner must land. Kept inside the shell's 12pt
    /// gutters, so the area never reaches into the neighbouring card.
    static let resizeGripOvershoot: CGFloat = 10
    /// How much the grip's tick grows on hover. Slight on purpose — it is a
    /// mark hugging the card's edge, not a button — just enough to answer the
    /// pointer before the press.
    static let resizeGripHoverScale: CGFloat = 1.2
    /// How wide a lane of cards is. A lane holding a `.screen` widget is wider
    /// — see `WidgetSize.width` — but this is the width of every other one,
    /// and of a lane that does not exist yet.
    public static let laneWidth: CGFloat = 300
    /// How wide an embedded app screen is. psymail's mail screen is laid out
    /// for this, and a card of controls' 300pt crowds its header and tab bar.
    static let screenWidth: CGFloat = 432
    /// How far the panel sits from the screen's top-right corner.
    public static let panelInset: CGFloat = Space.one

    /// Whether lanes these wide fit on a display this wide.
    ///
    /// The panel is anchored top-right and does not scroll, so widths past
    /// this are columns hanging off the left edge of the screen with nothing
    /// to say they are there. Edit mode refuses the drop that would make one
    /// rather than letting the arrangement grow somewhere the user can't see
    /// it (ccp-p6g). Measured against the lanes' real widths rather than a
    /// count, because a lane holding an app screen is wider than the rest —
    /// two of those fill a display a count of four would have called roomy.
    public static func fits(widths: [CGFloat], inWidth width: CGFloat) -> Bool {
        guard !widths.isEmpty else { return true }
        let usable = width - panelInset * 2 - Space.oneHalf * 2
        let needed = widths.reduce(0, +) + Space.oneHalf * CGFloat(widths.count - 1)
        return needed <= usable
    }

    /// Whether the display has room for one more lane beside these.
    ///
    /// The lane being offered is always the default width: only lanes already
    /// on the panel can be wider. A resize offering a wider lane asks
    /// `fits(widths:)` directly, with its own width substituted in.
    public static func fitsAnotherLane(beside laneWidths: [CGFloat], inWidth width: CGFloat) -> Bool {
        guard !laneWidths.isEmpty else { return true }
        return fits(widths: laneWidths + [laneWidth], inWidth: width)
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
        case .screen: 900
        }
    }

    /// How wide a lane must be to hold this widget. A card takes the lane it
    /// is given; an app screen brings its own width and the lane widens to it.
    var width: CGFloat {
        switch self {
        case .compact, .regular, .tall: Layout.laneWidth
        case .screen: Layout.screenWidth
        }
    }
}

public extension Layout {
    /// Height of the miniature graphs in the System Stats card.
    static let sparklineHeight: CGFloat = Space.three + Space.half // 28
    /// Size of a toggle icon button tile and its cell, in the Toggles widget.
    static let toggleIconSize: CGFloat = 44
    static let toggleCellWidth: CGFloat = 64
    /// The shortcut field in Settings. Fixed so the row doesn't reflow as the
    /// combination inside it grows from "⌘K" to "Type a shortcut".
    static let shortcutFieldWidth: CGFloat = 160
    /// A chip in the Shelf card's preview row. Wide enough that a name like
    /// "Package.swift" reads as one — at 44pt it truncated to "Pa…ift".
    static let shelfChipWidth: CGFloat = 64
    static let shelfChipIconWidth: CGFloat = 52
    static let shelfChipIconHeight: CGFloat = 32
    /// The round icon buttons that sit on a widget header's trailing edge.
    /// One size so two headers never disagree about how tall their line is.
    static let headerAccessorySize: CGFloat = 28
    /// The Settings window's content width — wide enough that a label and its
    /// shortcut field sit on one line without crowding.
    static let settingsWidth: CGFloat = 420
}
