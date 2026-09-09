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
    /// The notes folder, as a path. Nil means the default folder under
    /// Application Support. Plain text, not a bookmark: the app is not
    /// sandboxed, and a path stays readable in the file.
    public var notesFolderPath: String?

    public init(panelShortcut: String? = nil, notesFolderPath: String? = nil) {
        self.panelShortcut = panelShortcut
        self.notesFolderPath = notesFolderPath
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

    /// Where the notes folder lives right now, resolved the same way the
    /// adapter resolves it. Observed so the Settings row refreshes after a
    /// switch; the switch itself goes through `setNotesDirectory`, which
    /// moves the files first — never set this directly.
    public private(set) var notesFolderPath: String?

    /// The folder display and the adapter agree on: the Settings folder when
    /// one is set and usable, the default otherwise.
    public var notesDirectory: URL {
        NotesFileStore.resolveDirectory(settings: StoredSettings(notesFolderPath: notesFolderPath))
    }

    @ObservationIgnored private let file: JSONFileStore<StoredSettings>
    @ObservationIgnored private let notesDefaults: UserDefaults

    public init(file: JSONFileStore<StoredSettings> = JSONFileStore(
        filename: "settings.json",
        default: StoredSettings()
    ), notesDefaults: UserDefaults = .standard) {
        self.file = file
        self.notesDefaults = notesDefaults
        panelShortcut = file.load().panelShortcut.flatMap(KeyCombination.init(storageValue:))
        notesFolderPath = file.load().notesFolderPath
    }

    private func persist() {
        var stored = file.load()
        stored.panelShortcut = panelShortcut?.storageValue
        // The folder switch writes its own path rather than going through
        // here: persisting from the loaded copy would clobber a switch that
        // moved the files but has not finished writing. So this keeps the
        // loaded path.
        try? file.save(stored)
    }

    /// Point the notes folder at `url` — a vault subfolder, typically — or
    /// back at the default when nil. The pads' files move first; only when
    /// every move lands does the setting change, so a failed switch keeps
    /// the old folder rather than splitting the pads across two. The adapter
    /// relearns the folder from the notification, not from this return.
    public func setNotesDirectory(_ url: URL?) {
        let current = notesDirectory
        let next = url?.standardizedFileURL ?? NotesFileStore.defaultDirectory
        guard next != current else { return }
        // Files move before the setting commits, with rollback only on
        // thrown errors — a kill -9 between the two leaves the setting
        // naming the emptied folder and the pads reading blank, with the
        // texts intact where they moved to. Crash-atomic switches want a
        // pending-move marker that launch completes; that is filed work,
        // not this commit.
        let known = NotesFileStore(defaults: notesDefaults, directory: current).knownFilenames()
        do {
            try NotesFileStore(defaults: notesDefaults, directory: current)
                .relocate(filenames: known, to: next)
        } catch {
            return
        }
        var stored = file.load()
        stored.notesFolderPath = url?.standardizedFileURL.path
        guard (try? file.save(stored)) != nil else {
            // The setting did not stick: move the files back rather than
            // leaving them where nothing looks.
            try? NotesFileStore(defaults: notesDefaults, directory: next)
                .relocate(filenames: known, to: current)
            return
        }
        notesFolderPath = stored.notesFolderPath
        NotificationCenter.default.post(name: .notesFolderDidChange, object: nil)
    }
}
