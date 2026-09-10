// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Where a quota window *should* be if spend landed evenly, one day at a time.
///
/// A window is the `totalDays` before its reset, split into equal 24h slices
/// from its start — so weekly pace jumps at each UTC midnight off its Monday
/// reset, and monthly pace at each 24h mark off its own reset. Whole slices
/// only: the fill sits still all day, then steps forward, which is what makes
/// it read as a reference rather than a second readout.
///
/// Nil when there is no reset to split (offline, first run) — the caller
/// hides the underlay rather than guessing.
public enum UsagePace {
    public static func fraction(now: Date, resetsAt: Date?, totalDays: Int) -> Double? {
        guard let resetsAt, totalDays > 0 else { return nil }
        let day: TimeInterval = 86400
        let start = resetsAt.addingTimeInterval(-TimeInterval(totalDays) * day)
        let elapsedDays = floor(now.timeIntervalSince(start) / day)
        return min(1, max(0, elapsedDays / Double(totalDays)))
    }
}
