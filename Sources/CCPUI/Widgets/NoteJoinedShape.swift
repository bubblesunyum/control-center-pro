// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

/// The silhouette the selected tab and the note share.
///
/// Two rounded rectangles abutted are not this shape: the eye finds the
/// hairline where they meet, and each casts its own shadow into the other. This
/// unions them into one path, so the fill, the stroke and the elevation are
/// each drawn once over a single outline — which is the whole reason the tab
/// reads as the front edge of the note rather than a control parked beside it.
///
/// The tab's vertical position is the animatable value: selecting another note
/// slides the join down the rail instead of cutting to it.
struct NoteJoinedShape: Shape {
    /// Distance from the top of the surface to the top of the selected tab.
    var tabTop: CGFloat
    let railWidth: CGFloat
    let tabHeight: CGFloat
    let radius: CGFloat

    var animatableData: CGFloat {
        get { tabTop }
        set { tabTop = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let note = RoundedRectangle(cornerRadius: radius, style: .continuous)
            .path(in: CGRect(x: railWidth, y: 0,
                             width: max(0, rect.width - railWidth), height: rect.height))
        // The tab runs one radius past the rail so the union has real overlap
        // to work with; ending it exactly on the seam leaves an antialiased
        // line down the join.
        let tab = UnevenRoundedRectangle(topLeadingRadius: radius,
                                         bottomLeadingRadius: radius,
                                         bottomTrailingRadius: 0,
                                         topTrailingRadius: 0,
                                         style: .continuous)
            .path(in: CGRect(x: 0, y: tabTop, width: railWidth + radius, height: tabHeight))
        return note.union(tab)
    }
}
