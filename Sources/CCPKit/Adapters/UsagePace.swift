// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Where a quota window *should* be if spend landed evenly, one slice at a
/// time.
///
/// Every window steps hourly from its start. The 5-hour window reads where
/// even pace sits now; the weekly and monthly windows read where it sits at
/// the end of the current hour — ceiled to the next hour boundary — so a
/// mid-hour glance compares against what even spend allows by the hour's
/// close. Whole slices only: the fill sits still, then steps forward, which
/// is what makes it read as a reference rather than a second readout.
///
/// Nil when there is no reset to split (offline, first run) — the caller
/// hides the underlay rather than guessing.
public enum UsagePace {
    public static func fraction(
        now: Date,
        resetsAt: Date?,
        totalHours: Int,
        ceilToNextHour: Bool = false
    ) -> Double? {
        guard let resetsAt, totalHours > 0 else { return nil }
        let hour: TimeInterval = 3600
        let start = resetsAt.addingTimeInterval(-TimeInterval(totalHours) * hour)
        let rawSlices = now.timeIntervalSince(start) / hour
        let elapsedSlices = ceilToNextHour ? ceil(rawSlices) : floor(rawSlices)
        return min(1, max(0, elapsedSlices / Double(totalHours)))
    }
}
