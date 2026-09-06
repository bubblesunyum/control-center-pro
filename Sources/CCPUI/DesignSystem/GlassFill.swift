// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

/// The glass itself, shaped by the caller: `GlassCard` fills a rounded
/// rectangle, the drop-catcher pill a capsule. One place, so the Liquid Glass
/// branch and the legacy blur fallback can't drift apart per surface.
public struct GlassFill<S: Shape>: View {
    private let shape: S
    /// Radius for the legacy blur view only, which clips by points rather
    /// than by shape. The live path draws the true shape.
    private let cornerRadius: CGFloat

    public init(_ shape: S, cornerRadius: CGFloat) {
        self.shape = shape
        self.cornerRadius = cornerRadius
    }

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public var body: some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *), !reduceTransparency {
            shape
                .fill(Color.clear)
                .glassEffect(.regular, in: shape)
                .overlay(shape.fill(Color.cardFill))
        } else {
            VisualEffectViewRepresentable(cornerRadius: cornerRadius)
                .overlay(Color.cardFill)
                .clipShape(shape)
        }
#else
        VisualEffectViewRepresentable(cornerRadius: cornerRadius)
            .overlay(Color.cardFill)
            .clipShape(shape)
#endif
    }
}
