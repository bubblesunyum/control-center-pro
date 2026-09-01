// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// What the app lets you change. One thing so far: the combination that opens
/// the panel.
///
/// A stock grouped `Form` rather than the glass vocabulary — this is an
/// ordinary settings window and should look like every other one on the
/// system, not like the panel floating over the wallpaper.
struct SettingsView: View {
    @Bindable var settings: SettingsStore
    let hotkey: GlobalHotkey

    @State private var recorder = ShortcutRecorder.Status()

    var body: some View {
        Form {
            Section {
                LabeledContent("Open Control Center") {
                    ShortcutRecorder(
                        shortcut: $settings.panelShortcut,
                        onStatusChanged: recorderChanged
                    )
                }
            } footer: {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: Layout.settingsWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: String {
        if recorder.isRecording, !recorder.readsSystemShortcuts {
            return "Grant Accessibility in System Settings to record combinations "
                + "the system keeps for itself, like ⌘`."
        }
        if recorder.isRecording {
            return "Hold the combination, then let go. Escape cancels, Delete removes it."
        }
        if hotkey.isUnavailable {
            return "Another app is already using that shortcut. Try a different one."
        }
        return "Click to record a shortcut that opens the panel from anywhere."
    }

    /// The panel's own shortcut has to be given back to the system while a new
    /// one is being typed, or pressing the current combination opens the panel
    /// instead of landing in the field.
    private func recorderChanged(_ status: ShortcutRecorder.Status) {
        recorder = status
        status.isRecording ? hotkey.unregister() : hotkey.use(settings.panelShortcut)
    }
}
