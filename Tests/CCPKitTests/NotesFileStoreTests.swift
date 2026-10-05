// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

/// The files-and-index layer underneath the adapter: filename policy,
/// directory resolution, the index's corruption contract, and the
/// all-or-nothing folder move.
final class NotesFileStoreTests: XCTestCase {
    private func defaults(_ name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Filenames

    func testFilenameFollowsTheTitle() {
        XCTAssertEqual(NotesFileStore.filename(for: "Meeting", excluding: []), "Meeting.md")
    }

    func testFilenameReplacesSeparatorsAndTrims() {
        XCTAssertEqual(NotesFileStore.filename(for: "a/b:c\nd ", excluding: []), "a-b-c d.md")
    }

    func testDuplicateTitlesGetSuffixed() {
        let taken: Set<String> = ["Same.md", "Same-2.md"]
        XCTAssertEqual(NotesFileStore.filename(for: "Same", excluding: taken), "Same-3.md")
    }

    func testCaseVariantsDoNotAliasOnCaseInsensitiveDisks() {
        XCTAssertEqual(NotesFileStore.filename(for: "report", excluding: ["Report.md"]), "report-2.md")
        XCTAssertEqual(NotesFileStore.filename(for: "Report", excluding: ["report-2.md", "report.md"]),
                       "Report-3.md")
    }

    func testEmptyAndDotfileNamesFallBack() {
        XCTAssertEqual(NotesFileStore.filename(for: "   ", excluding: []), "Note.md")
        XCTAssertEqual(NotesFileStore.filename(for: ".hidden", excluding: []), "hidden.md")
    }

    func testDisplayNameIsTheStem() {
        XCTAssertEqual(NotesFileStore.displayName(for: "Meeting.md"), "Meeting")
        XCTAssertEqual(NotesFileStore.displayName(for: "Same-2.md"), "Same-2")
    }

    // MARK: - Directory resolution

    func testNilPathResolvesToTheDefault() {
        XCTAssertEqual(NotesFileStore.resolveDirectory(settings: StoredSettings()),
                       NotesFileStore.defaultDirectory)
    }

    func testAPathResolvesToItself() {
        let url = URL(fileURLWithPath: "/tmp/vault/notes", isDirectory: true)
        XCTAssertEqual(
            NotesFileStore.resolveDirectory(settings: StoredSettings(notesFolderPath: url.path)),
            url.standardizedFileURL)
    }

    func testAFileAtThePathFallsBackToTheDefault() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccp.notafolder.\(UUID().uuidString)")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            NotesFileStore.resolveDirectory(settings: StoredSettings(notesFolderPath: file.path)),
            NotesFileStore.defaultDirectory)
    }

    // MARK: - Index corruption contract

    func testLoadIndexIsAbsentWithoutAKey() throws {
        let name = "ccp.nfs.absent.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }

        XCTAssertEqual(NotesFileStore(defaults: store, directory: freshNotesDirectory()).loadIndex(),
                       .absent)
    }

    func testUndecodableIndexReadsAsUnreadableAndSetsAsideOnce() throws {
        let name = "ccp.nfs.setaside.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let garbage = Data("nope".utf8)
        store.set(garbage, forKey: "scratchpadNotesIndex")
        let fileStore = NotesFileStore(defaults: store, directory: freshNotesDirectory())

        XCTAssertEqual(fileStore.loadIndex(), .unreadable)
        let index = NotesFileIndex(selectedID: UUID(), pads: [])
        fileStore.saveIndex(index, settingAsideUnreadable: true)

        XCTAssertEqual(store.data(forKey: "scratchpadNotesIndex.unreadable"), garbage)
        XCTAssertEqual(fileStore.loadIndex(), .index(index, rescued: false))
    }

    func testSetAsideNeverOverwritesAnExistingRescue() throws {
        let name = "ccp.nfs.onceonly.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let first = Data("first".utf8)
        store.set(Data("second".utf8), forKey: "scratchpadNotesIndex")
        store.set(first, forKey: "scratchpadNotesIndex.unreadable")
        let fileStore = NotesFileStore(defaults: store, directory: freshNotesDirectory())

        fileStore.saveIndex(NotesFileIndex(selectedID: UUID(), pads: []),
                            settingAsideUnreadable: true)

        XCTAssertEqual(store.data(forKey: "scratchpadNotesIndex.unreadable"), first)
    }

    func testRescueIsConsumedOnReadback() throws {
        let name = "ccp.nfs.rescue.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        store.set(Data("live garbage".utf8), forKey: "scratchpadNotesIndex")
        let index = NotesFileIndex(selectedID: UUID(), pads: [])
        store.set(try JSONEncoder().encode(index), forKey: "scratchpadNotesIndex.unreadable")
        let fileStore = NotesFileStore(defaults: store, directory: freshNotesDirectory())

        XCTAssertEqual(fileStore.loadIndex(), .index(index, rescued: true))
        XCTAssertNil(store.data(forKey: "scratchpadNotesIndex.unreadable"),
                     "the rescue is consumed so a good live index never eats its own backup")
    }

    // MARK: - Text files

    func testUnreadableFileIsSetAsideOnWrite() throws {
        let dir = freshNotesDirectory()
        let name = "ccp.nfs.file.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let fileStore = NotesFileStore(defaults: store, directory: dir)
        try Data([0xFF, 0xFE]).write(to: dir.appendingPathComponent("Note.md"))

        try fileStore.writeText("new", filename: "Note.md")

        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("Note.md.corrupt")),
                       Data([0xFF, 0xFE]))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Note.md"), encoding: .utf8),
                       "new")
    }

    // MARK: - Relocate

    func testRelocateMovesListedFiles() throws {
        let first = freshNotesDirectory()
        let second = freshNotesDirectory()
        let name = "ccp.nfs.move.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let fileStore = NotesFileStore(defaults: store, directory: first)
        try fileStore.writeText("a", filename: "A.md")
        try fileStore.writeText("orphan", filename: "Orphan.md")

        try fileStore.relocate(filenames: ["A.md"], to: second)

        XCTAssertEqual(try String(contentsOf: second.appendingPathComponent("A.md"), encoding: .utf8), "a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.appendingPathComponent("A.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("Orphan.md").path),
                      "unlisted files stay")
    }

    func testRelocateRollsBackAPartialMove() throws {
        let first = freshNotesDirectory()
        let second = freshNotesDirectory()
        let name = "ccp.nfs.rollback.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let fileStore = NotesFileStore(defaults: store, directory: first)
        try fileStore.writeText("a", filename: "A.md")
        try fileStore.writeText("b", filename: "B.md")
        // The second move lands on a directory, which fails.
        try FileManager.default.createDirectory(at: second.appendingPathComponent("B.md"),
                                                withIntermediateDirectories: true)

        XCTAssertThrowsError(try fileStore.relocate(filenames: ["A.md", "B.md"], to: second))
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("A.md"), encoding: .utf8),
                       "a", "the moved file came back")
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("B.md"), encoding: .utf8),
                       "b")
    }

    // MARK: - Empty-over-nonempty refusal

    func testEmptyWriteOverNonemptyFileThrowsAndKeepsBytes() throws {
        let dir = freshNotesDirectory()
        let name = "ccp.nfs.refuse.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let fileStore = NotesFileStore(defaults: store, directory: dir)
        try fileStore.writeText("kept", filename: "Note.md")

        XCTAssertThrowsError(try fileStore.writeText("", filename: "Note.md")) { error in
            XCTAssertEqual(error as? NotesFileWriteError, .emptyOverNonempty(filename: "Note.md"))
        }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Note.md"), encoding: .utf8),
                       "kept")
    }

    func testEmptyWriteOverMissingFileCreatesIt() throws {
        let dir = freshNotesDirectory()
        let name = "ccp.nfs.fresh.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let fileStore = NotesFileStore(defaults: store, directory: dir)

        try fileStore.writeText("", filename: "Note.md")

        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Note.md"), encoding: .utf8), "")
    }

    func testEmptyWriteOverEmptyFileSucceeds() throws {
        let dir = freshNotesDirectory()
        let name = "ccp.nfs.stillempty.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let fileStore = NotesFileStore(defaults: store, directory: dir)
        try fileStore.writeText("", filename: "Note.md")

        XCTAssertNoThrow(try fileStore.writeText("", filename: "Note.md"))
    }

    func testEmptyWriteOverWhitespaceOnlyFileSucceeds() throws {
        // Debris zeroing is not loss: what reads as empty may be emptied.
        let dir = freshNotesDirectory()
        let name = "ccp.nfs.debris.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let fileStore = NotesFileStore(defaults: store, directory: dir)
        try "   ".write(to: dir.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)

        XCTAssertNoThrow(try fileStore.writeText("", filename: "Note.md"))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Note.md"), encoding: .utf8), "")
    }

    // MARK: - Trash

    func testDeleteMovesTheFileToTrash() throws {
        let dir = freshNotesDirectory()
        let name = "ccp.nfs.trash.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let fileStore = NotesFileStore(defaults: store, directory: dir)
        try fileStore.writeText("words", filename: "Note.md")

        fileStore.deleteFile("Note.md")

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Note.md").path))
        let trash = dir.appendingPathComponent(NotesFileStore.trashDirectoryName, isDirectory: true)
        let kept = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: trash.path))
        XCTAssertEqual(kept.count, 1)
        let trashed = try XCTUnwrap(kept.first)
        XCTAssertTrue(trashed.hasPrefix("Note-"), "the stem survives: \(trashed)")
        XCTAssertTrue(trashed.hasSuffix(".md"))
        XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent(trashed), encoding: .utf8),
                       "words")
    }

    func testDeleteOfAMissingFileIsSilent() throws {
        let dir = freshNotesDirectory()
        let name = "ccp.nfs.trashmiss.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let fileStore = NotesFileStore(defaults: store, directory: dir)

        fileStore.deleteFile("Nope.md")

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(NotesFileStore.trashDirectoryName).path))
    }

    func testMarkdownFilesIgnoresTrash() throws {
        let dir = freshNotesDirectory()
        let name = "ccp.nfs.noadopt.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let fileStore = NotesFileStore(defaults: store, directory: dir)
        try fileStore.writeText("doomed", filename: "A.md")

        fileStore.deleteFile("A.md")

        XCTAssertEqual(fileStore.markdownFiles(), [],
                       "a deleted note never adopts its way back")
    }

    func testPruneTrashRemovesOnlyOldEntries() throws {
        let dir = freshNotesDirectory()
        let name = "ccp.nfs.prune.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let fileStore = NotesFileStore(defaults: store, directory: dir)
        let trash = dir.appendingPathComponent(NotesFileStore.trashDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let old = trash.appendingPathComponent("Old-20200101T000000.md")
        let fresh = trash.appendingPathComponent("Fresh.md")
        try "old".write(to: old, atomically: true, encoding: .utf8)
        try "fresh".write(to: fresh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-25 * 3600)],
                                              ofItemAtPath: old.path)

        fileStore.pruneTrash()

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testDeleteTouchesTrashCopySoPruneKeepsFreshDeletes() throws {
        let dir = freshNotesDirectory()
        let name = "ccp.nfs.trashage.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let fileStore = NotesFileStore(defaults: store, directory: dir)
        try fileStore.writeText("old words", filename: "Old.md")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 24 * 3600)],
                                              ofItemAtPath: dir.appendingPathComponent("Old.md").path)

        fileStore.deleteFile("Old.md")
        fileStore.pruneTrash()

        let trash = dir.appendingPathComponent(NotesFileStore.trashDirectoryName, isDirectory: true)
        let kept = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: trash.path))
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent(kept[0]), encoding: .utf8),
                       "old words")
    }

    // MARK: - Adapter: delete and zeroing

    @MainActor
    private func notesAdapter(_ store: UserDefaults, dir: URL) -> NotesAdapter {
        // Local-only: a deactivate's trailing push must never reach past the
        // scripted transport, and sync is paused anyway.
        let adapter = NotesAdapter(defaults: store, defaultName: "Note", notesDirectory: dir,
                                   destination: CraftNoteDestination(defaults: store))
        adapter.craftCredentialUnavailable = true
        return adapter
    }

    /// deleteNote leaves bytes in `.trash`, and a relaunch never resurrects
    /// the pad: the index no longer lists it and the listing never looks
    /// inside `.trash`.
    @MainActor
    func testDeleteNoteTrashesAndStaysDeleted() throws {
        let name = "ccp.nfs.trashnote.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let dir = freshNotesDirectory()
        let adapter = notesAdapter(store, dir: dir)
        adapter.text = "doomed"
        adapter.createNote()
        let doomed = try XCTUnwrap(adapter.notes.first(where: { $0.text == "doomed" })?.id)

        XCTAssertTrue(adapter.deleteNote(doomed))

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       [NotesFileStore.trashDirectoryName, "Note 2.md"])
        let trash = dir.appendingPathComponent(NotesFileStore.trashDirectoryName, isDirectory: true)
        let kept = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: trash.path))
        XCTAssertEqual(kept.count, 1)
        let trashed = try XCTUnwrap(kept.first)
        XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent(trashed), encoding: .utf8),
                       "doomed")

        let second = notesAdapter(store, dir: dir)
        XCTAssertFalse(second.notes.map(\.id).contains(doomed))
        XCTAssertEqual(NotesFileStore(defaults: store, directory: dir).markdownFiles(), ["Note 2.md"])
    }

    /// Zeroing a saved pad's file on disk, then saving, leaves the non-empty
    /// bytes intact while memory keeps the user's text.
    @MainActor
    func testZeroingASavedPadKeepsDiskBytes() throws {
        let name = "ccp.nfs.zero.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let dir = freshNotesDirectory()
        let adapter = notesAdapter(store, dir: dir)
        adapter.text = "kept"
        adapter.deactivate()
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Note 1.md"), encoding: .utf8),
                       "kept")

        adapter.text = ""
        adapter.deactivate()

        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Note 1.md"), encoding: .utf8),
                       "kept", "zeroing leaves non-empty bytes intact")
        XCTAssertEqual(adapter.text, "", "memory keeps the user's text")
    }
}
