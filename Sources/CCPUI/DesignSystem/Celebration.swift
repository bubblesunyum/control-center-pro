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

/// The answer to the glow: a springy checkmark seal that pops in when
/// something finishes and dismisses the celebration when tapped. It
/// acknowledges — it never starts the next thing itself.
public struct CelebrationSeal: View {
    private let accessibilityLabel: String
    private let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popped = false

    public init(accessibilityLabel: String, action: @escaping () -> Void) {
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: Self.diameter, height: Self.diameter)
                .background(Circle().fill(Color.success))
                .scaleEffect(popped ? 1 : 0.4)
                .opacity(popped ? 1 : 0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .onAppear {
            guard !reduceMotion else { return popped = true }
            withAnimation(.bouncy(duration: 0.5)) { popped = true }
        }
    }

    private static let diameter: CGFloat = 40
}
