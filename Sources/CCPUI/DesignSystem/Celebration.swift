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
    @Environment(\.panelVisibility) private var visibility
    @State private var loopPhase: LoopPhase = .rest

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Color.widgetAccent.opacity(fillOpacity))
            )
            .shadow(
                color: .widgetAccent.opacity(shadowOpacity),
                radius: loopPhase == .rest ? 0 : 14
            )
            .task(id: shouldGlow) {
                if shouldGlow {
                    await LoopPhase.runLoop(
                        $loopPhase,
                        entry: .easeOut(duration: 0.25),
                        looping: .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                    )
                } else {
                    LoopPhase.settleLoop($loopPhase, animation: .easeOut(duration: 0.3))
                }
            }
    }

    private var shouldGlow: Bool { isActive && !reduceMotion && (visibility?.isVisible ?? true) }

    private var fillOpacity: Double {
        switch loopPhase {
        case .rest: 0
        case .low: 0.12
        case .high: 0.30
        }
    }

    private var shadowOpacity: Double {
        switch loopPhase {
        case .rest: 0
        case .low: 0.18
        case .high: 0.5
        }
    }
}
