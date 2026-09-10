// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

/// The quiet-until-hovered chip for icon buttons. Secondary at rest, one
/// step brighter over a muted fill under the pointer.
///
/// One owner so the call-sites can't drift apart — they previously each kept
/// their own hover flag around the same two lines.
struct HoverChip: ViewModifier {
    /// Optional foreground override; nil takes the standard
    /// secondary-to-primary step.
    var tint: Color?

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(tint ?? (isHovered ? Color.primary : Color.secondary))
            .background {
                RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
                    .fill(isHovered ? Color.controlFill : Color.clear)
            }
            .onHover { isHovered = $0 }
    }
}

extension View {
    /// Wears the shared icon-button hover chip, with an optional foreground
    /// override. Frames, fonts, and hit shapes stay with the caller — only
    /// the hover behaviour lives here.
    func hoverChip(tint: Color? = nil) -> some View {
        modifier(HoverChip(tint: tint))
    }
}
