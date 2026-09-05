// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// What the app lets you change: the combination that opens the panel, and
/// the Craft connection Notes syncs towards.
///
/// A stock grouped `Form` rather than the glass vocabulary — this is an
/// ordinary settings window and should look like every other one on the
/// system, not like the panel floating over the wallpaper.
struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Bindable var craft: CraftConnectionModel
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

            Section {
                if craft.isConfigured {
                    LabeledContent("Status") {
                        Text(craft.statusText)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Verify") { craft.verify() }
                        Button("Forget", role: .destructive) { craft.forget() }
                    }
                } else {
                    SecureField("Connection URL", text: $craft.urlText)
                        .textContentType(.URL)
                        .accessibilityLabel("Craft connection URL")
                    Button("Connect") { craft.save() }
                        .disabled(craft.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if craft.status == .invalidURL {
                        Text("That is not a Craft connection URL. It starts with https://connect.craft.do/links/…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if craft.status == .unreachable {
                        Text("Could not save to the Keychain — nothing was stored. Your text is still in the field.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Craft Sync")
            } footer: {
                Text("Create an API connection in Craft's Imagine tab and paste its URL here. "
                    + "The URL is the credential: it lives in the Keychain and is never shown again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: Layout.settingsWidth)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            if craft.isConfigured { craft.verify() }
        }
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
