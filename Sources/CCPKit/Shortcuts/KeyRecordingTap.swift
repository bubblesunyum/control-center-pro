// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import VorssaintEngines

/// Takes every key press for as long as a shortcut recorder is listening.
///
/// A key combination the system has claimed for itself — ⌘` cycling an app's
/// windows, ⌘Space opening search — never reaches an app at all, so a recorder
/// built on ordinary events can capture every shortcut except the ones a user
/// most wants to take back. This sits ahead of the system and hands those
/// presses to the recorder instead.
///
/// It is upstream's tap, and it wants Accessibility: `begin` returns false
/// without it, and a recorder that hears no is expected to fall back to
/// ordinary events rather than refuse to record.
@MainActor
public enum KeyRecordingTap {
    /// - Returns: whether the tap exists. False means no Accessibility.
    @discardableResult
    public static func begin(
        _ onPress: @escaping (Int64, KeyCombination.Modifiers) -> Void
    ) -> Bool {
        BridgedKeyRecordingTap.begin { keyCode, modifiers in
            onPress(keyCode, KeyCombination.Modifiers(bridged: modifiers))
        }
    }

    /// Gives the keyboard back. Safe to call twice, and when `begin` said no.
    public static func end() {
        BridgedKeyRecordingTap.end()
    }
}
