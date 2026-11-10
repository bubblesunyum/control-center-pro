// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import CoreGraphics

/// Decides which screen points are the panel's own content and which are
/// backdrop. Split out from the controller so the hit-test policy stays
/// provable without ordering windows: every member is pure.
enum PanelBackdrop {
    /// Outward slack on each card in edit mode. The resize target overshoots
    /// its card and the remove badge caps past it — without slack a press
    /// there would dismiss edit mode instead of resizing or removing.
    static let editHitTestOutset: CGFloat = 12

    /// Which rects count as the panel's: the cards, each with slack in edit
    /// mode for the controls hanging off its corners. Never the lanes' box —
    /// lanes run the height of the display, so their box covers glass the
    /// user sees as empty, and a click there must dismiss (or leave edit
    /// mode). A press mid-gesture never reaches this: the controller treats
    /// any drag in flight as the panel's. Nil frames mean the first report
    /// hasn't arrived, so the box stands in; an empty panel reports nothing
    /// to click and is all backdrop. Pure so the mode rule is provable
    /// without ordering windows.
    static func hitRects(lanesFrame: CGRect, cardFrames: [CGRect]?, isEditing: Bool) -> [CGRect] {
        guard let cardFrames else { return [lanesFrame] }
        guard isEditing else { return cardFrames }
        return cardFrames.map { $0.insetBy(dx: -editHitTestOutset, dy: -editHitTestOutset) }
    }

    /// Whether the screen point is the panel's own content. Pure so the
    /// hit-test math is provable without ordering windows: panel rects are
    /// top-leading origin, screen points are bottom-leading. Sticky geometry
    /// reads through the card's own frame helper — one definition shared with
    /// the desk and the drag guard.
    ///
    /// The rects are tested as a union, not as their bounding box: the
    /// gutters between cards are blank backdrop, and a point there is outside
    /// the panel — it dismisses (and is swallowed) rather than reaching the
    /// app below. The caller picks the set:
    /// the cards' frames at rest, the lanes' box until they arrive, in edit
    /// mode, and never for an empty panel (no rects at all is all backdrop).
    static func isInteractive(
        at screenPoint: CGPoint,
        windowFrame: CGRect,
        hitRects: [CGRect],
        stickies: [Sticky],
        galleryOpen: Bool
    ) -> Bool {
        if galleryOpen { return true }
        let toScreen = { (panel: CGRect) in CGRect(
            x: windowFrame.minX + panel.minX,
            y: windowFrame.maxY - panel.maxY,
            width: panel.width,
            height: panel.height
        ) }
        if hitRects.contains(where: { toScreen($0).contains(screenPoint) }) { return true }
        return stickies.contains { sticky in
            toScreen(StickyCard.frame(of: sticky, inWidth: windowFrame.size.width))
                .contains(screenPoint)
        }
    }
}
