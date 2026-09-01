// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import Observation
import VorssaintEngines

/// The app's settings as they sit on disk: names and text, nothing derived.
///
/// The shortcut is kept as its storage string rather than as a
/// `KeyCombination` so the file stays readable and a combination this build
/// no longer considers valid can be dropped on load instead of failing the
/// whole decode.
public struct StoredSettings: Codable, Equatable, Sendable {
    public var panelShortcut: String?

    public init(panelShortcut: String? = nil) {
        self.panelShortcut = panelShortcut
    }
}

/// What the user has chosen, and the file it survives in.
///
/// Small and rarely written — a settings change is a click, not a drag — so it
/// saves on every mutation rather than debouncing the way the layout does.
@MainActor
@Observable
public final class SettingsStore {
    /// The combination that opens and closes the panel. Nil means the panel
    /// has no shortcut and the app claims no key: taking one system-wide
    /// without being asked is not ours to do.
    public var panelShortcut: KeyCombination? {
        didSet { persist() }
    }

    @ObservationIgnored private let file: JSONFileStore<StoredSettings>

    public init(file: JSONFileStore<StoredSettings> = JSONFileStore(
        filename: "settings.json",
        default: StoredSettings()
    )) {
        self.file = file
        panelShortcut = file.load().panelShortcut.flatMap(KeyCombination.init(storageValue:))
    }

    private func persist() {
        try? file.save(StoredSettings(panelShortcut: panelShortcut?.storageValue))
    }
}
