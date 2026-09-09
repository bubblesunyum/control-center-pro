// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

public extension View {
    /// An attention glow that says "come look" until it is answered: a soft
    /// accent shadow breathing on the view while active, settling clean when
    /// it stops. Still under Reduce Motion.
    func celebrationGlow(isActive: Bool) -> some View {
        modifier(CelebrationGlow(isActive: isActive))
    }
}

/// An attention glow that says "come look" until it is answered: the card
/// washes with accent and breathes under a soft shadow while active,
/// settling clean when it stops. One driver for both, so fill and shadow
/// never drift out of phase. Still under Reduce Motion.
private struct CelebrationGlow: ViewModifier {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Color.widgetAccent.opacity(glowNow ? (lit ? 0.30 : 0.12) : 0))
            )
            .shadow(
                color: .widgetAccent.opacity(glowNow ? (lit ? 0.5 : 0.18) : 0),
                radius: glowNow ? 14 : 0
            )
            .animation(
                glowNow
                    ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.3),
                value: lit
            )
            .task(id: glowNow) {
                lit = glowNow
            }
    }

    private var glowNow: Bool { isActive && !reduceMotion }
}
