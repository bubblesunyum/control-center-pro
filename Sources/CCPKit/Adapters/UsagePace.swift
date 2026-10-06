// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Where a quota window *should* be if spend landed evenly.
///
/// The 5-hour window steps hourly from its start and reads where even pace
/// sits now. The weekly and monthly windows step a whole day at a time on
/// the local calendar — day one reads a full day from the first minute, so
/// today's spend has something to stand against — and hold until midnight.
///
/// Whole slices only: the fill sits still, then steps forward, which is
/// what makes it read as a reference rather than a second readout.
///
/// Nil when there is no reset to split (offline, first run) — the caller
/// hides the underlay rather than guessing.
public enum UsagePace {
    public static func fraction(
        now: Date,
        resetsAt: Date?,
        totalHours: Int
    ) -> Double? {
        guard let resetsAt, totalHours > 0 else { return nil }
        let hour: TimeInterval = 3600
        let start = resetsAt.addingTimeInterval(-TimeInterval(totalHours) * hour)
        let elapsedSlices = floor(now.timeIntervalSince(start) / hour)
        return min(1, max(0, elapsedSlices / Double(totalHours)))
    }

    /// Whole days, today included: the first minute of a fresh window reads
    /// 1/totalDays, and the fill steps at each local midnight.
    ///
    /// The window still runs resetsAt minus totalDays of wall time — only
    /// the readout quantises to calendar days.
    public static func dailyFraction(
        now: Date,
        resetsAt: Date?,
        totalDays: Int,
        calendar: Calendar = .current
    ) -> Double? {
        guard let resetsAt, totalDays > 0 else { return nil }
        let day: TimeInterval = 86400
        let start = resetsAt.addingTimeInterval(-TimeInterval(totalDays) * day)
        guard now >= start else { return 0 }
        let elapsedDays = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: start),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        return min(1, max(0, Double(elapsedDays + 1) / Double(totalDays)))
    }
}
