// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import CoreGraphics

/// Decides which screen points are the panel's own content and which are
/// backdrop. Split out from the controller so the hit-test policy stays
/// provable without ordering windows: every member is pure.
enum PanelBackdrop {
    /// Outward slack on the edit-mode hit box. The resize target overshoots
    /// its card and the remove badge caps past it, and on an edge card that
    /// overhang sits past the lanes' outer boundary where the box doesn't
    /// reach — without slack a press there dismisses and exits edit mode
    /// instead of resizing or removing.
    static let editHitTestOutset: CGFloat = 12

    /// Which rects count as the panel's. At rest the cards' union is exact,
    /// so gutter clicks are backdrop; editing keeps the lanes' box (with
    /// slack) because the union would punch holes mid-gesture — the lifted
    /// card leaves its lane as a frameless gap, and backdrop under a held
    /// drag would dismiss from under it. Nil frames mean the first
    /// report hasn't arrived, so the box stands in; an empty panel reports
    /// nothing to click and is all backdrop. Pure so the mode rule is provable
    /// without ordering windows.
    static func hitRects(lanesFrame: CGRect, cardFrames: [CGRect]?, isEditing: Bool) -> [CGRect] {
        if isEditing {
            return [lanesFrame.insetBy(dx: -editHitTestOutset, dy: -editHitTestOutset)]
        }
        return cardFrames ?? [lanesFrame]
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
