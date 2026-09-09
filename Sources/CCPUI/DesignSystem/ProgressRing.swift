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
    @State private var breath = false

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
        .scaleEffect(breathingNow ? (breath ? 1.05 : 1.0) : 1.0)
        .animation(
            breathingNow
                ? .easeInOut(duration: 2.2).repeatForever(autoreverses: true)
                : .easeOut(duration: 0.3),
            value: breath
        )
        .task(id: breathingNow) {
            breath = breathingNow
        }
        .accessibilityHidden(true)
    }

    private var breathingNow: Bool { isBreathing && !reduceMotion }
}
