// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

/// A round progress readout: a quiet track with the caller's tint filling as
/// `fraction` climbs.
///
/// Breathes while `isBreathing` — a slow scale loop that says "running" without
/// spending a digit — and parks dead still otherwise. Still under Reduce Motion.
public struct ProgressRing: View {
    public let fraction: Double
    public let tint: Color
    public let isBreathing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelVisibility) private var visibility
    @State private var loopPhase: LoopPhase = .rest

    private static let lineWidth: CGFloat = 6

    public init(fraction: Double, tint: Color = .widgetAccent, isBreathing: Bool = false) {
        self.fraction = fraction
        self.tint = tint
        self.isBreathing = isBreathing
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Color.ringTrack, lineWidth: Self.lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .scaleEffect(loopScale)
        .task(id: shouldBreathe) {
            if shouldBreathe {
                await LoopPhase.runLoop(
                    $loopPhase,
                    entry: .easeOut(duration: 0.25),
                    looping: .easeInOut(duration: 2.2).repeatForever(autoreverses: true)
                )
            } else {
                LoopPhase.settleLoop($loopPhase, animation: .easeOut(duration: 0.3))
            }
        }
        .accessibilityHidden(true)
    }

    private var loopScale: CGFloat { loopPhase == .high ? 1.05 : 1.0 }

    private var shouldBreathe: Bool {
        isBreathing && !reduceMotion && (visibility?.isVisible ?? true)
    }
}
