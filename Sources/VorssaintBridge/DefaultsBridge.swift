// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Registers upstream's UserDefaults — availability and per-feature defaults.
///
/// `AppFeature.availabilityDefaults` is the only thing that makes
/// `AppFeature.isAvailable` true for the features we ship; without it
/// `ClipboardHistoryService.syncWithPreferences` sees the feature as
/// unavailable and never starts, which is why the Enable button did nothing
/// (`ccp-6qp`). The shim keeps the call site in `ControlCenterPro` from
/// naming an internal type.
public enum BridgedDefaults {
    public static func register() {
        Defaults.register()
    }
}
