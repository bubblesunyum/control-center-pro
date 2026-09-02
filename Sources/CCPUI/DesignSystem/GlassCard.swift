// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

/// The pane every widget is drawn on: a lightening of the panel's blur, a
/// hairline, a continuous radius, a soft shadow.
///
/// The glass is the widget's own: each card blurs the desktop behind it rather
/// than sitting on one panel-wide blur, so there is no container to notice —
/// just tiles of frosted glass on the wallpaper.
///
/// It clips and it does not pad. Where a card holds rows, the rows carry the
/// inset and draw their own hover fill to the card's full inner width — pad the
/// container instead and every highlight stops short of the edge. Widgets whose
/// content is not a list reach for ``WidgetCard``, which adds the inset back.
public struct GlassCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let isRaised: Bool
    private let content: Content

    public init(isRaised: Bool = false, @ViewBuilder content: () -> Content) {
        self.isRaised = isRaised
        self.content = content()
    }

    public var body: some View {
        content
            .background { glassBackground }
            .clipShape(shape)
            .overlay(shape.strokeBorder(isRaised ? Color.cardStrokeStrong : Color.cardStroke, lineWidth: Stroke.hairline))
            .shadow(color: .cardShadow, radius: isRaised ? 16 : 8, y: isRaised ? 8 : 2)
    }

    @ViewBuilder
    private var glassBackground: some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *), !reduceTransparency {
            shape
                .fill(Color.clear)
                .glassEffect(.regular, in: shape)
                .overlay(shape.fill(Color.cardFill))
        } else {
            VisualEffectViewRepresentable(cornerRadius: Radius.card)
                .overlay(Color.cardFill)
                .clipShape(shape)
        }
#else
        VisualEffectViewRepresentable(cornerRadius: Radius.card)
            .overlay(Color.cardFill)
            .clipShape(shape)
#endif
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
    }
}
