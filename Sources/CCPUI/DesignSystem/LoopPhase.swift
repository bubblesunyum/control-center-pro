// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

/// The phase of a repeating loop that genuinely stops.
///
/// A `repeatForever` animator is displaced only by a real change of the value
/// it drives, applied under a finite animation. Gating the *drawn* value on
/// an active flag stops drawing motion but leaves the forever animator
/// ticking rest↔rest for the life of the process (ccp-7imm: ~70% idle CPU
/// with the panel shut). So a drawn value is always a pure function of this
/// phase, and stopping is a phase change — a loop endpoint back to rest —
/// under a finite animation.
///
/// Three states because "off" and "loop trough" differ: the celebration
/// glow's rest (no fill, no shadow) is not its low breath (a faint wash).
/// Starting takes two legs — rest→low under a short entry, then low→high
/// under the forever — so the forever oscillates low↔high and the model sits
/// at high while looping; stopping from either endpoint is then always a real
/// change, even where low and rest draw identically.
enum LoopPhase: Equatable, Sendable {
    case rest
    case low
    case high

    /// Parked at rest: nothing looping, nothing to stop.
    var isSettled: Bool { self == .rest }

    /// First leg of starting: rest→low. Nil when already away from rest.
    func start() -> LoopPhase? {
        self == .rest ? .low : nil
    }

    /// Second leg of starting: low→high, applied under the forever animation
    /// so the loop oscillates low↔high. Nil unless waiting at low.
    func loop() -> LoopPhase? {
        self == .low ? .high : nil
    }

    /// Stopping: either endpoint back to rest, under a finite animation that
    /// displaces the forever animator. Nil when already at rest, so stopping
    /// a settled loop touches nothing and installs nothing.
    func stop() -> LoopPhase? {
        self == .rest ? nil : .rest
    }
}

extension LoopPhase {
    /// Gap between the entry and forever legs, so they commit as separate
    /// transactions. Any suspension would do; this also lets the entry ease
    /// visibly begin before the loop takes over.
    private static let entryHop = Duration.milliseconds(50)

    /// Runs one activation of the loop: the entry leg under `entry`, then the
    /// forever leg under `looping`. Each leg reads the phase fresh and applies
    /// its own animation explicitly — no `.animation(_:value:)` modifier — so
    /// a stop landing between legs still wins: `loop()` computed from a
    /// settled phase is nil and applies nothing.
    @MainActor
    static func runLoop(
        _ phase: Binding<LoopPhase>,
        startDelay: Duration = .zero,
        entry: Animation,
        looping: Animation
    ) async {
        if startDelay > .zero {
            // Zero tolerance: where a delay desynchronises cards (wiggle),
            // coalesced wakeups would restart them in lockstep.
            try? await Task.sleep(for: startDelay, tolerance: .zero)
            guard !Task.isCancelled else { return }
        }
        if let next = phase.wrappedValue.start() {
            withAnimation(entry) { phase.wrappedValue = next }
        } else if phase.wrappedValue != .low {
            return
        }
        try? await Task.sleep(for: entryHop, tolerance: .zero)
        guard !Task.isCancelled else { return }
        if let next = phase.wrappedValue.loop() {
            withAnimation(looping) { phase.wrappedValue = next }
        }
    }

    /// Parks the loop at rest under a finite animation, which is what
    /// displaces the forever animator. A settled loop is left untouched.
    @MainActor
    static func settleLoop(_ phase: Binding<LoopPhase>, animation: Animation) {
        if let next = phase.wrappedValue.stop() {
            withAnimation(animation) { phase.wrappedValue = next }
        }
    }
}
