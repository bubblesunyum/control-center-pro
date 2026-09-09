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
}
