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

    /// Height of the scrollable projects list. The card never caps its own
    /// content — `WidgetSize.tall` is a floor, not a ceiling — so an
    /// unbounded section list grows the lane off screen. Past this the
    /// sections scroll instead, matching the clipboard's capped list above.
    static let projectsListHeight: CGFloat = 330

    /// How tall the note editor stands. Live-styled Markdown needs the
    /// room: at 148pt a heading and a short list filled the card, and a note you
    /// cannot see is a worse note than a plain-text one. Set here rather than on
    /// `WidgetSize.tall`, which the clipboard shares and which would leave dead
    /// glass under its own capped list.
    static let noteEditorHeight: CGFloat = 300

    /// One tab in the Notes header strip. Twelve tabs never fit a lane, so
    /// the strip scrolls and follows the selection.
    static let noteTabHeight: CGFloat = 24
    /// How wide one tab may grow before its name truncates. Fits a default
    /// "Note 12" plus its close cell at headline size, with a little air.
    static let noteTabMaxWidth: CGFloat = 92
    /// How tall the fade above the note toolbar stands. Taller than a line
    /// of text, so the last line dissolves instead of clipping hard.
    static let noteToolbarFadeHeight: CGFloat = Space.three + Space.half // 28

    /// Size of a row's leading icon and trailing menu button.
    static let rowActionSize: CGFloat = 22
    /// Thumbnail shown on the leading edge of an image clipboard row.
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
    /// How wide a card that was never resized is, and so a lane of them —
    /// and of a lane that does not exist yet.
    public static let laneWidth: CGFloat = 300
    /// How wide an embedded app screen is until it is resized. A card of
    /// controls' 300pt crowds a screen's header and tab bar; this is the
    /// width mail's lines read best at.
    static let screenWidth: CGFloat = 486
    /// How far the panel sits from the screen's top-right corner.
    public static let panelInset: CGFloat = Space.one
    /// The whole-window frost behind the lanes: how present it reads. AppKit
    /// exposes no blur radius, so intensity is opacity — the blurred result
    /// blended back toward the raw desktop. Below 1 so the wallpaper stays
    /// legible through it; the cards carry their own stronger glass.
    public static let backdropBlurOpacity: Double = 0.55
    /// The dim over the frost. A whisper: it must read as depth behind the
    /// panel, not as the display going dark.
    public static let backdropDimOpacity: Double = 0.10
    /// How tall the fade at the window's top edge stands. The seat starts
    /// right under the menu bar, and an unfaded frost would draw a hard line
    /// across the wallpaper there.
    public static let backdropFeatherHeight: CGFloat = 40

    /// The width the lanes may share on a display this wide: the display
    /// minus the panel's inset and content padding on both sides, so there
    /// is always a margin left and right.
    static func usableWidth(inWidth width: CGFloat) -> CGFloat {
        width - panelInset * 2 - Space.oneHalf * 2
    }

    /// The lanes as they draw on a display this wide: as stored when they
    /// fit, shrunk in proportion when they don't.
    ///
    /// A resize can never make the lanes overflow — it clamps to the room
    /// beside the other lanes — so the shrink only runs when the room itself
    /// changed: a smaller display, a layout from a bigger one. Drawing
    /// anyway would hang a column off an edge with nothing to say it is
    /// there, and the panel window is cut to the display, so whatever does
    /// not fit is simply gone. Nothing is written back; on the display the
    /// layout came from it draws at its real size again.
    static func fittedLaneWidths(_ widths: [CGFloat], inWidth width: CGFloat) -> [CGFloat] {
        guard !widths.isEmpty else { return [] }
        let room = usableWidth(inWidth: width) - Space.oneHalf * CGFloat(widths.count - 1)
        let needed = widths.reduce(0, +)
        guard needed > room, needed > 0 else { return widths }
        let scale = max(room, 0) / needed
        return widths.map { $0 * scale }
    }

    /// Whether lanes these wide fit on a display this wide.
    ///
    /// The panel is anchored top-right and never scrolls sideways, so widths
    /// past this are columns with nowhere to draw. Edit mode refuses the
    /// drop that would make one rather than letting the arrangement grow
    /// somewhere the user can't see it (ccp-p6g). Measured against the
    /// lanes' real widths rather than a count, because lanes are as wide as
    /// their widest card.
    public static func fits(widths: [CGFloat], inWidth width: CGFloat) -> Bool {
        guard !widths.isEmpty else { return true }
        let usable = usableWidth(inWidth: width)
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

    /// The widest one lane may draw while the other lanes stay put: the
    /// usable width minus the other lanes and the gutters between all of
    /// them. Same accounting as `fits(widths:inWidth:)`, solved for the one
    /// lane. The live drag and the commit both clamp to this, so a drag past
    /// the edge parks at the edge instead of snapping back on release.
    public static func maxLaneWidth(beside others: [CGFloat], inWidth width: CGFloat) -> CGFloat {
        usableWidth(inWidth: width) - others.reduce(0, +) - Space.oneHalf * CGFloat(others.count)
    }
}

public extension WidgetSize {
    /// The height a widget of this size stands at least until it is resized.
    /// A widget whose content needs more gets it, so this is the floor that
    /// keeps a lane of small widgets from looking ragged — not a limit on
    /// what a resize may do.
    var height: CGFloat {
        switch self {
        case .compact: 64
        case .regular: 132
        case .tall: 232
        case .screen: 900
        }
    }

    /// How wide a widget of this size is until it is resized.
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
    /// Size of a tool icon button tile and its cell. Sized so four cells
    /// fit the lane's content width and the strip reads four across.
    static let toolIconSize: CGFloat = 44
    static let toolCellWidth: CGFloat = 60
    /// The shortcut field in Settings. Fixed so the row doesn't reflow as the
    /// combination inside it grows from "⌘K" to "Type a shortcut".
    static let shortcutFieldWidth: CGFloat = 160
    /// A chip in the Shelf card's preview row. Wide enough that a name like
    /// "Package.swift" reads as one — at 44pt it truncated to "Pa…ift".
    static let shelfChipWidth: CGFloat = 64
    static let shelfChipIconWidth: CGFloat = 52
    static let shelfChipIconHeight: CGFloat = 32
    /// Thumbnail in the Files card's shelf and download rows.
    static let shelfPreviewWidth: CGFloat = 42
    static let shelfPreviewHeight: CGFloat = 56
    /// Thumbnail in the Files card's minimized strip: one horizontal row of
    /// pinned and download items. Square and small — a glanceable summary, not a preview.
    static let shelfMinimizedThumbnailSize: CGFloat = 32
    /// Fallback icon sizes inside those thumbnails: the full row's 42×56
    /// preview centers a 24pt icon, the minimized 32pt square a 20pt one.
    static let shelfPreviewIconSize: CGFloat = 24
    static let shelfMinimizedThumbnailIconSize: CGFloat = 20
    /// How wide a minimized thumbnail's hover title may grow before its name
    /// truncates from the middle.
    static let shelfMinimizedTipMaxWidth: CGFloat = 220
    /// The Files overflow menu: how wide the popover stands, how tall one row is.
    static let shelfMenuWidth: CGFloat = 220
    static let shelfMenuRowHeight: CGFloat = 32
    /// The sync popover's conflict panes: a list beside its content, so the
    /// popover stands roughly twice as wide as a single-column menu. A cap,
    /// not a floor — the panes scroll internally past it.
    static let syncPopoverWidth: CGFloat = 420
    static let syncPopoverConflictListWidth: CGFloat = 150
    static let syncPopoverConflictsHeight: CGFloat = 240
    /// How many version rows the sync popover shows before scrolling. The
    /// ring holds ten; uncapped, the popover runs off the bottom of a laptop
    /// screen. Derived from the row height so the two cannot drift.
    static let syncPopoverHistoryHeight: CGFloat = 6 * shelfMenuRowHeight
    /// The round icon buttons that sit on a widget header's trailing edge.
    /// One size so two headers never disagree about how tall their line is.
    static let headerAccessorySize: CGFloat = 28
    /// The Settings window's content width — wide enough that a label and its
    /// shortcut field sit on one line without crowding.
    static let settingsWidth: CGFloat = 420
    /// The minimum size of a website login popup sheet. A login page narrower
    /// than this crowds its own form; the sheet grows with its content past it.
    static let websitePopupMinWidth: CGFloat = 480
    static let websitePopupMinHeight: CGFloat = 360
    /// A newborn popup web view's frame: a real window size, not zero. Some
    /// login flows measure their window on open and bail on a zero rect —
    /// which the site reports as blocking popups. Throwaway (first layout
    /// replaces it); kept here so the throwaway reads as deliberate.
    static let websitePopupInitialSize = CGSize(width: 800, height: 600)
    /// A HUD toast: how wide its message may grow before truncating, how long
    /// it lingers, and how fast it fades in and out. One set so every
    /// widget's toast reads as one — the Tools and Projects copies drifted
    /// here before they were extracted (ccp-irhh).
    static let hudMessageMaxWidth: CGFloat = 360
    static let hudDismissDelay: Double = 1.5
    static let hudFadeInDuration: Double = 0.12
    static let hudFadeOutDuration: Double = 0.22
    /// How far below the visible frame's top edge a HUD toast sits. Three
    /// steps — one past the panel's own inset, so the toast floats on the
    /// desktop rather than reading as pinned to glass.
    static let hudTopOffset: CGFloat = Space.three
    /// Where a HUD toast lands when no screen reports a visible frame. Off
    /// to the side rather than centered — this path only fires headless.
    static let hudFallbackOrigin: CGFloat = 200
}
