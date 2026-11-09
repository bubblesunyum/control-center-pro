// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// The panel hotkey's hold-to-peek rule, pure so the timing is provable
/// without registering a system key.
///
/// A quick tap toggles: press shows (or arms a hide) and a release inside the
/// threshold leaves the toggled state standing. Holding past the threshold
/// arms peek mode instead — the press already showed the panel, and the
/// release that ends the hold hides it again. Releasing either key ends the
/// hold (Carbon reports the combination released when any part lets go), so
/// a peek that ends with one key still down re-shows on that key's re-press:
/// that press is just another press while hidden.
public enum HotkeyHoldPolicy {
    /// How long the combination must be held before the release hides instead
    /// of leaving the toggled state standing.
    public static let holdThreshold: TimeInterval = 1.0

    /// Whether the press should show the panel now. Showing on press (rather
    /// than on release) is what makes a hold a peek: the panel is already up
    /// while the keys are down.
    public static func shouldShowOnPress(isVisible: Bool) -> Bool {
        !isVisible
    }

    /// Whether the release should hide the panel. A release that had the
    /// panel up when the press landed always hides — quick toggle-off and
    /// hold-release alike. A release from hidden hides only after a hold:
    /// that is the peek ending, while a quick tap stays up.
    public static func shouldHideOnRelease(wasVisibleAtPress: Bool, pressDuration: TimeInterval) -> Bool {
        if wasVisibleAtPress { return true }
        return pressDuration >= holdThreshold
    }
}
