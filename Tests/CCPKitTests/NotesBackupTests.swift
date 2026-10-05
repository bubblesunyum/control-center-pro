// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

/// The 5-minute snapshot layer under the termination flush: staged snapshots
/// named by UTC timestamp, a 24h prune, and a manual-copy restore that
/// recovers texts, names, order and selection.
final class NotesBackupTests: XCTestCase {
    private func defaults(_ name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func freshDirectory(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix).\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func backup(notesDir: URL, appSupport: URL, defaults: UserDefaults) -> NotesBackupStore {
        NotesBackupStore(defaults: defaults, appSupportDirectory: appSupport, notesDirectory: notesDir)
    }

    private func seedIndex(texts: [(filename: String, name: String, text: String)],
                           selected: Int = 0,
                           into store: UserDefaults,
                           dir: URL) throws -> NotesFileIndex {
        let fileStore = NotesFileStore(defaults: store, directory: dir)
        var entries: [NotesFileIndexEntry] = []
        for seed in texts {
            try fileStore.writeText(seed.text, filename: seed.filename)
            entries.append(NotesFileIndexEntry(id: UUID(), filename: seed.filename, name: seed.name,
                                               modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        }
        let index = NotesFileIndex(selectedID: entries[selected].id, pads: entries)
        fileStore.saveIndex(index)
        return index
    }

    // MARK: - Snapshots

    func testSnapshotCopiesNotesThenIndexAndCompanions() throws {
        let dir = freshDirectory(prefix: "ccp.notes")
        let appSupport = freshDirectory(prefix: "ccp.apphost")
        let name = "ccp.backup.full.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let index = try seedIndex(texts: [("A.md", "A", "alpha"), ("B.md", "B", "beta")],
                                  selected: 1, into: store, dir: dir)
        for companion in NotesBackupStore.companionFilenames {
            try "\(companion) body".write(to: appSupport.appendingPathComponent(companion),
                                         atomically: true, encoding: .utf8)
        }

        let snapshot = try backup(notesDir: dir, appSupport: appSupport, defaults: store).snapshot()

        XCTAssertEqual(snapshot.deletingLastPathComponent().lastPathComponent,
                       NotesBackupStore.backupsFolderName)
        let stamp = snapshot.lastPathComponent
        XCTAssertNotNil(stamp.range(of: #"^\d{8}T\d{6}$"#, options: .regularExpression),
                        "UTC timestamp name: \(stamp)")
        XCTAssertEqual(try String(contentsOf: snapshot.appendingPathComponent("A.md"), encoding: .utf8),
                       "alpha")
        XCTAssertEqual(try String(contentsOf: snapshot.appendingPathComponent("B.md"), encoding: .utf8),
                       "beta")
        XCTAssertEqual(try Data(contentsOf: snapshot.appendingPathComponent(NotesBackupStore.indexFilename)),
                       store.data(forKey: "scratchpadNotesIndex"))
        XCTAssertEqual(index.pads.count, 2)
        for companion in NotesBackupStore.companionFilenames {
            XCTAssertEqual(try String(contentsOf: snapshot.appendingPathComponent(companion),
                                       encoding: .utf8),
                           "\(companion) body")
        }
    }

    func testSnapshotSkipsMissingCompanionsAndIndex() throws {
        let dir = freshDirectory(prefix: "ccp.notes")
        let appSupport = freshDirectory(prefix: "ccp.apphost")
        let name = "ccp.backup.sparse.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        try NotesFileStore(defaults: store, directory: dir).writeText("words", filename: "A.md")

        let snapshot = try backup(notesDir: dir, appSupport: appSupport, defaults: store).snapshot()

        XCTAssertEqual(try String(contentsOf: snapshot.appendingPathComponent("A.md"), encoding: .utf8),
                       "words")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: snapshot.appendingPathComponent(NotesBackupStore.indexFilename).path))
    }

    func testSameSecondSnapshotsDoNotCollide() throws {
        let dir = freshDirectory(prefix: "ccp.notes")
        let appSupport = freshDirectory(prefix: "ccp.apphost")
        let name = "ccp.backup.twice.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let backups = backup(notesDir: dir, appSupport: appSupport, defaults: store)
        let now = Date()

        let first = try backups.snapshot(now: now)
        let second = try backups.snapshot(now: now)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testSnapshotLeavesNoStagingBehind() throws {
        let dir = freshDirectory(prefix: "ccp.notes")
        let appSupport = freshDirectory(prefix: "ccp.apphost")
        let name = "ccp.backup.clean.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }

        try backup(notesDir: dir, appSupport: appSupport, defaults: store).snapshot()

        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: appSupport.appendingPathComponent(NotesBackupStore.backupsFolderName).path)
        XCTAssertTrue(leftovers.allSatisfy { !$0.hasPrefix(".staging-") }, "\(leftovers)")
    }

    // MARK: - Prune

    func testPruneRemovesDayOldSnapshotsAndKeepsFresh() throws {
        let dir = freshDirectory(prefix: "ccp.notes")
        let appSupport = freshDirectory(prefix: "ccp.apphost")
        let name = "ccp.backup.prune.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let backups = backup(notesDir: dir, appSupport: appSupport, defaults: store)
        let fresh = try backups.snapshot()
        let old = appSupport.appendingPathComponent(NotesBackupStore.backupsFolderName)
            .appendingPathComponent("20200101T000000", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-25 * 3600)],
                                              ofItemAtPath: old.path)
        let staging = appSupport.appendingPathComponent(NotesBackupStore.backupsFolderName)
            .appendingPathComponent(".staging-dead", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        backups.prune()

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "day-old backups prune")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "killed runs clean up")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testRunPrunesTheNotesTrash() throws {
        let dir = freshDirectory(prefix: "ccp.notes")
        let appSupport = freshDirectory(prefix: "ccp.apphost")
        let name = "ccp.backup.trash.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let fileStore = NotesFileStore(defaults: store, directory: dir)
        try fileStore.writeText("gone", filename: "A.md")
        fileStore.deleteFile("A.md")
        let trash = dir.appendingPathComponent(NotesFileStore.trashDirectoryName, isDirectory: true)
        let trashed = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: trash.path).first)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-25 * 3600)],
                                              ofItemAtPath: trash.appendingPathComponent(trashed).path)

        backup(notesDir: dir, appSupport: appSupport, defaults: store).run()

        XCTAssertFalse(FileManager.default.fileExists(atPath: trash.appendingPathComponent(trashed).path))
    }

    // MARK: - Restore

    /// The documented manual copy, performed in code: wipe the notes folder,
    /// the index and the companions, then hand-restore the newest snapshot
    /// and read everything back.
    func testRoundTripRestoreRecoversTextsNamesOrderAndSelection() throws {
        let dir = freshDirectory(prefix: "ccp.notes")
        let appSupport = freshDirectory(prefix: "ccp.apphost")
        let name = "ccp.backup.roundtrip.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let index = try seedIndex(texts: [("A.md", "Alpha", "first words"),
                                          ("B.md", "Beta", "second words"),
                                          ("C.md", "Gamma", "third words")],
                                  selected: 2, into: store, dir: dir)
        for companion in NotesBackupStore.companionFilenames {
            try "\(companion) body".write(to: appSupport.appendingPathComponent(companion),
                                         atomically: true, encoding: .utf8)
        }
        try backup(notesDir: dir, appSupport: appSupport, defaults: store).snapshot()

        // The disaster: the whole notes folder and the small files are gone.
        try FileManager.default.removeItem(at: dir)
        store.removeObject(forKey: "scratchpadNotesIndex")
        for companion in NotesBackupStore.companionFilenames {
            try? FileManager.default.removeItem(at: appSupport.appendingPathComponent(companion))
        }

        // The manual restore: newest snapshot's .md files back into the notes
        // folder, companions back over their names, index bytes back under
        // their key.
        let root = appSupport.appendingPathComponent(NotesBackupStore.backupsFolderName)
        let newest = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }.sorted().last)
        let snap = root.appendingPathComponent(newest, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for entry in try FileManager.default.contentsOfDirectory(atPath: snap.path)
            where entry.hasSuffix(".md") {
            try FileManager.default.copyItem(at: snap.appendingPathComponent(entry),
                                             to: dir.appendingPathComponent(entry))
        }
        for companion in NotesBackupStore.companionFilenames {
            try FileManager.default.copyItem(at: snap.appendingPathComponent(companion),
                                             to: appSupport.appendingPathComponent(companion))
        }
        store.set(try Data(contentsOf: snap.appendingPathComponent(NotesBackupStore.indexFilename)),
                  forKey: "scratchpadNotesIndex")

        let restored = NotesFileStore(defaults: store, directory: dir)
        guard case .index(let loaded, _) = restored.loadIndex() else {
            return XCTFail("the restored index decodes")
        }
        XCTAssertEqual(loaded, index, "names, order and selection survive")
        let expected = ["A.md": "first words", "B.md": "second words", "C.md": "third words"]
        for entry in index.pads {
            XCTAssertEqual(restored.readText(filename: entry.filename), expected[entry.filename])
        }
        for companion in NotesBackupStore.companionFilenames {
            XCTAssertEqual(try String(contentsOf: appSupport.appendingPathComponent(companion),
                                       encoding: .utf8),
                           "\(companion) body")
        }
    }

    // MARK: - Cadence

    func testSnapshotIntervalBoundsLossAtFiveMinutes() {
        XCTAssertEqual(NotesBackupStore.snapshotInterval, 5 * 60,
                       "a kill -9 between backups loses at most 5 minutes")
        XCTAssertEqual(NotesBackupStore.retention, 24 * 60 * 60,
                       "day-old backups prune")
    }

    func testDefaultInitFollowsTheSettingsFolder() throws {
        let dir = freshDirectory(prefix: "ccp.notes")
        let appSupport = freshDirectory(prefix: "ccp.apphost")
        let name = "ccp.backup.resolve.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let settings = StoredSettings(notesFolderPath: dir.path)
        let settingsData = try JSONEncoder().encode(settings)
        try settingsData.write(to: appSupport.appendingPathComponent("settings.json"), options: .atomic)
        try NotesFileStore(defaults: store, directory: dir).writeText("here", filename: "A.md")

        // No notes directory handed in: resolves through the settings file.
        let snapshot = try NotesBackupStore(defaults: store, appSupportDirectory: appSupport).snapshot()

        XCTAssertEqual(try String(contentsOf: snapshot.appendingPathComponent("A.md"), encoding: .utf8),
                       "here")
    }
}
