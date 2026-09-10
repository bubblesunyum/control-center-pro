// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Where a quota window *should* be if spend landed evenly, one slice at a
/// time.
///
/// A window is the slices before its reset, split into equal steps from its
/// start — days for the weekly and monthly windows (so weekly pace jumps at
/// each UTC midnight off its Monday reset), hours for the 5-hour window.
/// Whole slices only: the fill sits still, then steps forward, which is what
/// makes it read as a reference rather than a second readout.
///
/// Nil when there is no reset to split (offline, first run) — the caller
/// hides the underlay rather than guessing.
public enum UsagePace {
    public static func fraction(now: Date, resetsAt: Date?, totalDays: Int) -> Double? {
        guard totalDays > 0 else { return nil }
        return stepped(now: now, resetsAt: resetsAt, slices: totalDays, sliceLength: 86400)
    }

    public static func fraction(now: Date, resetsAt: Date?, totalHours: Int) -> Double? {
        guard totalHours > 0 else { return nil }
        return stepped(now: now, resetsAt: resetsAt, slices: totalHours, sliceLength: 3600)
    }

    private static func stepped(now: Date, resetsAt: Date?, slices: Int, sliceLength: TimeInterval) -> Double? {
        guard let resetsAt else { return nil }
        let start = resetsAt.addingTimeInterval(-TimeInterval(slices) * sliceLength)
        let elapsedSlices = floor(now.timeIntervalSince(start) / sliceLength)
        return min(1, max(0, elapsedSlices / Double(slices)))
    }
}
