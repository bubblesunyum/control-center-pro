// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Observation

/// A stand-in for the periodic work a real widget does, so the panel has one
/// widget that genuinely starts and stops.
///
/// The lifecycle it is here to exercise is the one thing about a widget the
/// shell can get wrong on its own: a sampler that outlives the panel is the
/// difference between an app that costs nothing while shut and one that
/// doesn't, and it cannot be proven against widgets that never sample at all.
/// The engine that replaces this will own its own timer the same way.
@MainActor
@Observable
final class PlaceholderSampler {
    /// How many times it has sampled. What it reads is meaningless; that it
    /// changes, and only while the panel is open, is the point.
    private(set) var tick = 0

    @ObservationIgnored private var sampling: Task<Void, Never>?

    private static let interval = Duration.seconds(1)

    var isSampling: Bool { sampling != nil }

    /// Starting an already-running sampler does nothing, which is what keeps
    /// twenty opens from leaving twenty timers behind.
    func start() {
        guard sampling == nil else { return }
        sampling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled else { return }
                self?.tick += 1
            }
        }
    }

    func stop() {
        sampling?.cancel()
        sampling = nil
    }
}
