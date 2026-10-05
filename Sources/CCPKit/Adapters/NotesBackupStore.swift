// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Periodic snapshots of the notes folder plus the small JSON companions.
///
/// Each run copies the note `.md` files first, then the index and
/// `settings.json` + `stickies.json` + `shelf.json` + `layout.json`, into
/// `Backups-Notes/<UTC-timestamp>/` under Application Support — staged in a
/// hidden sibling dir and renamed into place, so a kill -9 lands either a
/// whole snapshot or nothing. The same run prunes snapshot dirs older than
/// 24h (plus stale staging dirs and the notes `.trash`), which bounds a
/// kill -9's loss to one snapshot interval.
///
/// Restore v1 is a manual file copy, while the app is quit:
/// 1. Pick the newest `Backups-Notes/<timestamp>/` dir.
/// 2. Copy its `*.md` files back into the notes folder (the Settings folder
///    when one is set, `Notes` under Application Support otherwise).
/// 3. Copy its `settings.json`, `stickies.json`, `shelf.json`, `layout.json`
///    back over the same names in Application Support.
/// 4. Write `scratchpadNotesIndex.json`'s bytes back to the
///    `scratchpadNotesIndex` default — that is the tab order and selection.
/// 5. Relaunch: texts, names, order and selection are back. The round-trip
///    test below performs exactly these steps.
public struct NotesBackupStore {
    public static let backupsFolderName = "Backups-Notes"
    public static let indexFilename = "scratchpadNotesIndex.json"
    public static let settingsFilename = "settings.json"
    public static let stickiesFilename = "stickies.json"
    public static let shelfFilename = "shelf.json"
    public static let layoutFilename = "layout.json"
    public static let companionFilenames = [settingsFilename, stickiesFilename, shelfFilename, layoutFilename]
    /// Seconds between snapshots. A kill -9 loses at most this much.
    public static let snapshotInterval: TimeInterval = 5 * 60
    /// Snapshots older than this are pruned on every run.
    public static let retention: TimeInterval = 24 * 60 * 60

    private let notesDirectory: URL
    private let appSupportDirectory: URL
    private let defaults: UserDefaults
    private let indexKey: String

    /// - Parameter notesDirectory: nil follows the Settings folder, the same
    ///   way the adapter resolves it; tests hand a temporary folder instead.
    public init(defaults: UserDefaults = .standard,
                indexKey: String = "scratchpadNotesIndex",
                appSupportDirectory: URL = .applicationSupport,
                notesDirectory: URL? = nil) {
        self.defaults = defaults
        self.indexKey = indexKey
        self.appSupportDirectory = appSupportDirectory
        if let notesDirectory {
            self.notesDirectory = notesDirectory
        } else {
            let settings = JSONFileStore<StoredSettings>(filename: Self.settingsFilename,
                                                         default: StoredSettings(),
                                                         in: appSupportDirectory).load()
            self.notesDirectory = NotesFileStore.resolveDirectory(settings: settings)
        }
    }

    public var backupsDirectory: URL {
        appSupportDirectory.appendingPathComponent(Self.backupsFolderName, isDirectory: true)
    }

    private var fileStore: NotesFileStore {
        NotesFileStore(defaults: defaults, directory: notesDirectory, indexKey: indexKey)
    }

    /// The periodic pass: snapshot, prune day-old snapshots, prune the notes
    /// trash. Best-effort throughout — a timer and termination flush call
    /// this where there is nobody to report to.
    public func run(now: Date = Date()) {
        try? snapshot(now: now)
        prune(now: now)
        fileStore.pruneTrash(now: now)
    }

    /// One snapshot, returned at its final name. Throws: the periodic pass
    /// above swallows it, tests assert on it.
    @discardableResult
    public func snapshot(now: Date = Date()) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let staging = backupsDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            // Texts first: a torn snapshot strands words without an index,
            // never an index pointing at words it does not hold.
            for filename in fileStore.markdownFiles() {
                let source = notesDirectory.appendingPathComponent(filename)
                guard manager.fileExists(atPath: source.path) else { continue }
                try manager.copyItem(at: source, to: staging.appendingPathComponent(filename))
            }
            if let data = defaults.data(forKey: indexKey) {
                try data.write(to: staging.appendingPathComponent(Self.indexFilename), options: .atomic)
            }
            for filename in Self.companionFilenames {
                let source = appSupportDirectory.appendingPathComponent(filename)
                guard manager.fileExists(atPath: source.path) else { continue }
                try manager.copyItem(at: source, to: staging.appendingPathComponent(filename))
            }
            let destination = uniqueSnapshotDirectory(now: now)
            try manager.moveItem(at: staging, to: destination)
            return destination
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    /// Drops snapshot dirs older than ``retention`` and any staging dir a
    /// killed run left behind. An undatable entry is kept, never pruned.
    public func prune(now: Date = Date()) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: backupsDirectory.path) else { return }
        for name in names {
            let url = backupsDirectory.appendingPathComponent(name)
            if name.hasPrefix(".staging-") {
                try? manager.removeItem(at: url)
                continue
            }
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            guard NotesFileStore.isExpired(modified: modified, now: now, olderThan: Self.retention)
            else { continue }
            try? manager.removeItem(at: url)
        }
    }

    private func uniqueSnapshotDirectory(now: Date) -> URL {
        let name = NotesFileStore.uniqueTimestampedName(base: NotesFileStore.utcTimestamp(now)) {
            FileManager.default.fileExists(atPath: backupsDirectory.appendingPathComponent($0).path)
        }
        return backupsDirectory.appendingPathComponent(name, isDirectory: true)
    }
}
