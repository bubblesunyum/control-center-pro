// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

/// The handle every resizable card answers with: the iPadOS windowing
/// resize tick, a short rounded corner hugging the card's own. Shared by
/// the lane grips and the sticky corner zone — one tick shape, not one per
/// caller (ccp-ebxu).
///
/// A short arc concentric with the card's own corner: the grip box's outer
/// corner sits exactly on the card's, so centering the arc one card-radius
/// in hugs the edge. Inset half a step inside the hairline — flush, it
/// would read as a broken border rather than a mark.
struct CornerTick: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.maxX - Radius.card, y: rect.maxY - Radius.card),
            radius: Radius.card - Space.half,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        return path
    }
}
