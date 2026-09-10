// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

/// Local truth is a folder of markdown files plus an index in UserDefaults.
/// These are the tests that keep the files honest: the migration clears the
/// old keys only after the files verify, corruption never destroys
/// evidence, and the trash/close split (delete the file vs keep it) holds.
@MainActor
final class NotesDocumentStorageTests: XCTestCase {
    private let padID = UUID(uuidString: "50642B4A-4533-43DF-BD75-282FC55E7286")!

    private func storedJSON(key: String, id: UUID? = nil, text: String = "kept") -> Data {
        let id = (id ?? padID).uuidString
        return Data("""
        {"\(key)":[{"text":"\(text)","id":"\(id)","name":"Scratchpad"}],
         "selectedID":"\(id)"}
        """.utf8)
    }

    private func defaults(_ name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func notesAdapter(_ store: UserDefaults, dir: URL,
                              destination: CraftNoteDestination? = nil) -> NotesAdapter {
        // Local-only unless a test says otherwise: a deactivate's trailing
        // push must never reach past the scripted transport.
        let adapter = NotesAdapter(defaults: store, defaultName: "Note", notesDirectory: dir,
                                   destination: destination ?? CraftNoteDestination(defaults: store))
        adapter.craftCredentialUnavailable = true
        return adapter
    }

    private func files(in dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
    }

    // MARK: - Fresh launch and migration

    func testFreshLaunchWritesAnIndexAndAFile() throws {
        let name = "ccp.notes.fresh.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let dir = freshNotesDirectory()

        let adapter = notesAdapter(store, dir: dir)

        XCTAssertNotNil(store.data(forKey: "scratchpadNotesIndex"), "the index is the state now")
        XCTAssertEqual(files(in: dir), ["Note 1.md"])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Note 1.md"), encoding: .utf8), "")
        XCTAssertEqual(adapter.text, "")
    }

    func testMigrationMovesTheBlobToFilesAndClearsOldKeys() throws {
        let name = "ccp.notes.migrate.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        store.set(storedJSON(key: "pads"), forKey: "scratchpadDocument")
        let dir = freshNotesDirectory()

        let adapter = notesAdapter(store, dir: dir)

        XCTAssertEqual(adapter.text, "kept")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Scratchpad.md"), encoding: .utf8), "kept")
        XCTAssertNil(store.data(forKey: "scratchpadDocument"), "a verified migration clears the blob")
        XCTAssertNil(store.data(forKey: "scratchpadDocument.unreadable"))
        XCTAssertNil(store.data(forKey: "scratchpadClosedTabs"))
    }

    /// One build wrote the Swift property name into the blob.
    func testMigrationReadsTheNotesKeyOneBuildWrote() throws {
        let name = "ccp.notes.mignotes.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        store.set(storedJSON(key: "notes"), forKey: "scratchpadDocument")

        let adapter = notesAdapter(store, dir: freshNotesDirectory())

        XCTAssertEqual(adapter.text, "kept")
        XCTAssertNil(store.data(forKey: "scratchpadDocument"))
    }

    func testMigrationCarriesClosedTabsAndLeavesCraftKeysAlone() throws {
        let name = "ccp.notes.migclosed.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let other = UUID()
        let doc = NotesDocument(
            notes: [Note(id: padID, name: "A", text: "kept"),
                    Note(id: other, name: "B", text: "also kept")],
            selectedID: other)
        store.set(try JSONEncoder().encode(doc), forKey: "scratchpadDocument")
        store.set(try JSONEncoder().encode(Set([padID])), forKey: "scratchpadClosedTabs")
        store.set(Data("{\"doc1\":\"x\"}".utf8), forKey: "scratchpadCraftDocuments")
        let dir = freshNotesDirectory()

        let adapter = notesAdapter(store, dir: dir)

        XCTAssertEqual(adapter.closedNotes.map(\.id), [padID])
        XCTAssertEqual(adapter.openNotes.map(\.id), [other])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("A.md"), encoding: .utf8), "kept")
        XCTAssertEqual(store.data(forKey: "scratchpadCraftDocuments"),
                       Data("{\"doc1\":\"x\"}".utf8),
                       "Craft bookkeeping is untouched by the migration")
    }

    // MARK: - The corruption contract

    func testUnreadableIndexStandsAPlaceholderAndWritesNothing() throws {
        let name = "ccp.notes.unreadable.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let garbage = Data("{\"this\":\"is not an index\"}".utf8)
        store.set(garbage, forKey: "scratchpadNotesIndex")
        let dir = freshNotesDirectory()

        let adapter = notesAdapter(store, dir: dir)
        adapter.activate()
        adapter.deactivate()

        XCTAssertEqual(adapter.text, "", "an empty stand-in, not the user's state")
        XCTAssertEqual(store.data(forKey: "scratchpadNotesIndex"), garbage,
                       "loading — and closing — must not replace bytes it could not read")
        XCTAssertNil(store.data(forKey: "scratchpadNotesIndex.unreadable"),
                     "and must not have needed the rescue key at all")
        XCTAssertEqual(files(in: dir), [], "no files either: the stand-in never persists")
    }

    /// A backup nothing reads back is not a recovery path.
    func testARescuedIndexIsReadBackWhenThisBuildCanDecodeIt() throws {
        let name = "ccp.notes.readback.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let garbage = Data("not an index".utf8)
        store.set(garbage, forKey: "scratchpadNotesIndex")
        let index = NotesFileIndex(selectedID: padID,
                                   pads: [NotesFileIndexEntry(id: padID, filename: "Scratchpad.md",
                                                             name: "Scratchpad")])
        store.set(try JSONEncoder().encode(index), forKey: "scratchpadNotesIndex.unreadable")
        let dir = freshNotesDirectory()
        try "kept".write(to: dir.appendingPathComponent("Scratchpad.md"),
                         atomically: true, encoding: .utf8)

        let adapter = notesAdapter(store, dir: dir)

        XCTAssertEqual(adapter.text, "kept", "the rescued pads come back")
        XCTAssertNotNil(try? JSONDecoder().decode(NotesFileIndex.self,
                                                  from: XCTUnwrap(store.data(forKey: "scratchpadNotesIndex"))),
                        "the rescue re-commits so the pads survive a quit")
        XCTAssertEqual(store.data(forKey: "scratchpadNotesIndex.unreadable"), garbage,
                       "and the unreadable live bytes are set aside, not dropped")
    }

    func testTheFirstRealEditMovesUnreadableBytesAsideRatherThanOverThem() throws {
        let name = "ccp.notes.rescue.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let garbage = Data("{\"this\":\"is not an index\"}".utf8)
        store.set(garbage, forKey: "scratchpadNotesIndex")
        let dir = freshNotesDirectory()

        let adapter = notesAdapter(store, dir: dir)
        adapter.text = "something new"
        adapter.deactivate()

        XCTAssertEqual(store.data(forKey: "scratchpadNotesIndex.unreadable"), garbage,
                       "the unreadable index is kept under its own key")
        XCTAssertNotEqual(store.data(forKey: "scratchpadNotesIndex"), garbage,
                          "and the new note is saved normally")
    }

    func testMissingFileIsAnEmptyPad() throws {
        let name = "ccp.notes.missing.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let dir = freshNotesDirectory()
        let first = notesAdapter(store, dir: dir)
        first.text = "kept"
        first.deactivate()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Note 1.md"))

        let second = notesAdapter(store, dir: dir)

        XCTAssertEqual(second.notes.count, 1, "the pad survives its missing file")
        XCTAssertEqual(second.text, "", "reading as empty, not as gone")
    }

    func testExtraFilesAreNeverAdopted() throws {
        let name = "ccp.notes.noadopt.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let dir = freshNotesDirectory()
        let first = notesAdapter(store, dir: dir)
        first.deactivate()
        try "stranger".write(to: dir.appendingPathComponent("Stranger.md"),
                             atomically: true, encoding: .utf8)

        let second = notesAdapter(store, dir: dir)

        XCTAssertEqual(second.notes.count, 1, "on-disk files the index never listed stay unlisted")
    }

    // MARK: - Files follow the tabs

    func testTrashDeletesTheFileCloseKeepsIt() throws {
        let name = "ccp.notes.trashfile.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let dir = freshNotesDirectory()
        let adapter = notesAdapter(store, dir: dir)
        adapter.text = "doomed"
        adapter.createNote()
        let doomed = try XCTUnwrap(adapter.notes.first(where: { $0.text == "doomed" })?.id)
        XCTAssertEqual(files(in: dir).count, 2)

        // Hiding keeps the doc: the file stays for the closed-tabs menu.
        XCTAssertTrue(adapter.closeTab(doomed))
        XCTAssertEqual(files(in: dir).count, 2)
        // The trash deletes the doc: the file goes with it.
        XCTAssertTrue(adapter.deleteNote(doomed))
        XCTAssertEqual(files(in: dir).count, 1)
    }

    func testRenameRenamesTheFile() throws {
        let name = "ccp.notes.rename.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let dir = freshNotesDirectory()
        let adapter = notesAdapter(store, dir: dir)
        let id = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = "words"

        adapter.renameNote(id, to: "Meeting")

        XCTAssertEqual(files(in: dir), ["Meeting.md"])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Meeting.md"), encoding: .utf8), "words")
        // And the mapping survived the rename: a relaunch still finds it.
        let second = notesAdapter(store, dir: dir)
        XCTAssertEqual(second.notes.first(where: { $0.id == id })?.name, "Meeting")
        XCTAssertEqual(second.text, "words")
    }

    func testDuplicateTitlesGetSuffixedFilenames() throws {
        let name = "ccp.notes.dups.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let dir = freshNotesDirectory()
        let adapter = notesAdapter(store, dir: dir)
        let first = try XCTUnwrap(adapter.selectedNoteID)
        adapter.renameNote(first, to: "Same")
        adapter.createNote()
        let second = try XCTUnwrap(adapter.selectedNoteID)
        adapter.renameNote(second, to: "Same")

        XCTAssertEqual(files(in: dir).sorted(), ["Same-2.md", "Same.md"])
    }

    // MARK: - Durable dirty (ccp-q3nd)

    /// The unit half: a mapped edit flushed locally — the panel closed, the
    /// push debounced, the process quit — is still dirty after relaunch.
    func testDirtySurvivesARelaunch() throws {
        let name = "ccp.notes.dirty.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let dir = freshNotesDirectory()
        let destination = CraftNoteDestination(defaults: store)
        let first = notesAdapter(store, dir: dir, destination: destination)
        first.craftCredentialUnavailable = true
        let id = try XCTUnwrap(first.selectedNoteID)
        destination.setCraftDocumentID("doc1", for: id)
        first.text = "unpushed"
        first.deactivate()

        let second = notesAdapter(store, dir: dir)

        XCTAssertTrue(second.isPushDirty(id), "the bit outlives the process now")
    }

    /// The scenario half: quit inside the push debounce used to strand the
    /// mapped edit — the activate pull skips (remote == sidecar) and nothing
    /// re-marked it. Now the relaunch owns the bit and the activate push
    /// spends it.
    func testRelaunchPushesDurableMappedEdits() async throws {
        let base = URL(string: "https://connect.craft.do/links/test/api/v1")!
        let clock = ScriptedTransport.Script(statusCode: 200, json: """
            {"space":{"name":"S"},"utc":{"time":"2026-09-06T19:00:00Z"}}
            """)
        let name = "ccp.notes.q3nd.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let dir = freshNotesDirectory()

        let scrub = ScriptedTransport([])
        let destination = CraftNoteDestination(defaults: store)
        let first = notesAdapter(store, dir: dir, destination: destination)
        first.craftCredentialUnavailable = false
        first.craftTransport = scrub
        first.craftBaseURLOverride = base
        let id = try XCTUnwrap(first.selectedNoteID)
        first.text = "before"
        destination.storeBase(.fixture("before"), for: id)
        destination.setCraftDocumentID("doc1", for: id)
        destination.storeSyncedTitle(first.selectedNoteName, for: id)
        await first.flushCraftPush()
        XCTAssertFalse(first.isPushDirty(id), "steady state starts clean")
        // The edit lands, the panel closes, the process quits inside the
        // 3s push debounce: deactivate flushes locally, the trailing push
        // finds an empty script queue and fails with the bit standing.
        first.text = "after"
        first.deactivate()

        let transport = ScriptedTransport([])
        transport.respond = { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query ?? ""
            if path.hasSuffix("/connection") { return clock }
            if request.httpMethod == "GET", query.contains("location=trash") {
                return .init(statusCode: 200, json: "{\"items\":[]}")
            }
            if request.httpMethod == "GET" {
                return .init(statusCode: 200, json: """
                    {"items":[{"id":"block-0","markdown":"before"}]}
                    """)
            }
            return .init(statusCode: 200, json: """
                {"items":[{"id":"block-0","markdown":"after"}]}
                """)
        }
        let relaunched = notesAdapter(store, dir: dir)
        relaunched.craftCredentialUnavailable = false
        relaunched.craftTransport = transport
        relaunched.craftBaseURLOverride = base
        XCTAssertTrue(relaunched.isPushDirty(id), "the relaunch owns the stranded edit")

        relaunched.activate()
        for _ in 0..<200 where relaunched.isSyncVerified == false || relaunched.isPushDirty(id) {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(relaunched.isSyncVerified, "the pull landed")
        XCTAssertFalse(relaunched.isPushDirty(id), "and the push spent the durable bit")
        let putIndex = try XCTUnwrap(transport.requests.firstIndex {
            $0.httpMethod == "PUT" && $0.url?.lastPathComponent == "blocks"
        }, "the edit reached Craft as an update")
        let body = try transport.jsonBody(of: putIndex)
        let blocks = try XCTUnwrap(body["blocks"] as? [[String: String]])
        XCTAssertEqual(blocks, [["id": "block-0", "markdown": "after"]])
        relaunched.deactivate()
    }

    // MARK: - Folder switch

    func testFolderSwitchMovesFilesAndKeepsThePads() throws {
        let name = "ccp.notes.switch.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let settingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccp.settings.\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            file: JSONFileStore(filename: "settings.json",
                                default: StoredSettings(),
                                in: settingsDir),
            notesDefaults: store)
        let dirA = freshNotesDirectory()
        let pads = notesAdapter(store, dir: dirA)
        let id = try XCTUnwrap(pads.selectedNoteID)
        pads.text = "moves with me"
        pads.deactivate()

        let box = PostedBox()
        let observer = NotificationCenter.default.addObserver(
            forName: .notesFolderDidChange, object: nil, queue: nil) { _ in box.posted = true }
        defer { NotificationCenter.default.removeObserver(observer) }
        settings.setNotesDirectory(dirA)
        let dirB = freshNotesDirectory()
        settings.setNotesDirectory(dirB)
        pads.useNotesDirectory(dirB)

        XCTAssertTrue(box.posted, "the switch notifies")
        XCTAssertEqual(settings.notesFolderPath, dirB.path)
        XCTAssertEqual(files(in: dirA), [], "every known file moved out")
        XCTAssertEqual(try String(contentsOf: dirB.appendingPathComponent("Note 1.md"), encoding: .utf8),
                       "moves with me")
        XCTAssertEqual(pads.notes.first(where: { $0.id == id })?.text, "moves with me")
        pads.text = "edited after the move"
        pads.deactivate()
        XCTAssertEqual(try String(contentsOf: dirB.appendingPathComponent("Note 1.md"), encoding: .utf8),
                       "edited after the move", "new edits land in the new folder")
    }

    // MARK: - Review findings

    /// A delete that never resurrects: the intermediate index writes inside
    /// deleteNote must not list the pad being deleted.
    func testDeleteStaysDeletedAcrossRelaunch() throws {
        let name = "ccp.notes.nodead.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let dir = freshNotesDirectory()
        let adapter = notesAdapter(store, dir: dir)
        adapter.text = "doomed"
        adapter.createNote()
        let doomed = try XCTUnwrap(adapter.notes.first(where: { $0.text == "doomed" })?.id)
        XCTAssertTrue(adapter.deleteNote(doomed))
        adapter.deactivate()

        let second = notesAdapter(store, dir: dir)

        XCTAssertEqual(second.notes.count, 1)
        XCTAssertFalse(second.notes.map(\.id).contains(doomed))
        XCTAssertEqual(files(in: dir).count, 1)
    }

    /// A failed migration keeps both legacy copies for the retry: the blob
    /// and its rescue stay, and no index appears.
    func testFailedMigrationKeepsTheLegacyKeys() throws {
        let name = "ccp.notes.migfail.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let blob = storedJSON(key: "pads")
        let rescue = storedJSON(key: "pads", text: "rescued")
        store.set(blob, forKey: "scratchpadDocument")
        store.set(rescue, forKey: "scratchpadDocument.unreadable")
        // A file, not a folder: every write fails, deterministically.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccp.blocker.\(UUID().uuidString)")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)

        _ = notesAdapter(store, dir: blocker)

        XCTAssertEqual(store.data(forKey: "scratchpadDocument"), blob)
        XCTAssertEqual(store.data(forKey: "scratchpadDocument.unreadable"), rescue,
                       "the rescue is consumed only after the files verify")
        XCTAssertNil(store.data(forKey: "scratchpadNotesIndex"))
    }

    /// The dirty bit's index write must avoid files on disk just like the
    /// persist does, or a quick type after an unreadable index points the
    /// pad at a stranger's file until the debounce lands.
    func testUnsavedIndexWriteAvoidsExistingFiles() throws {
        let name = "ccp.notes.provisional.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        store.set(Data("garbage".utf8), forKey: "scratchpadNotesIndex")
        let dir = freshNotesDirectory()
        try "stranger".write(to: dir.appendingPathComponent("Note 1.md"),
                             atomically: true, encoding: .utf8)

        let adapter = notesAdapter(store, dir: dir)
        adapter.text = "hi"

        let data = try XCTUnwrap(store.data(forKey: "scratchpadNotesIndex"))
        let decoded = try? JSONDecoder().decode(NotesFileIndex.self, from: data)
        XCTAssertEqual(try XCTUnwrap(decoded).pads.map(\.filename), ["Note 1-2.md"])
    }

    /// A rename whose move fails lands nothing: the old name, file and
    /// mapping all stand, with no half-moved folder behind them.
    func testFailedRenameKeepsTheOldState() throws {
        let name = "ccp.notes.renamefail.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let dir = freshNotesDirectory()
        let adapter = notesAdapter(store, dir: dir)
        let id = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = "v1"
        adapter.deactivate()
        let file = dir.appendingPathComponent("Note 1.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: dir.path) }
        // Self-calibrating: an environment that ignores permissions (root)
        // would land the move and fail the assertions below.
        let probe = dir.appendingPathComponent("probe")
        if FileManager.default.createFile(atPath: probe.path, contents: Data()) {
            throw XCTSkip("permissions are not enforced here")
        }

        adapter.text = "v2"
        adapter.renameNote(id, to: "Renamed")

        XCTAssertEqual(adapter.selectedNoteName, "Note 1", "the rename did not land")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "v1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Renamed.md").path))
    }

    /// Stranded mapped edits predate the durable bit: the migration marks
    /// them dirty by content and title, so the next push converges them
    /// instead of reading saved over stale Craft state.
    func testMigrationMarksStrandedMappedEditsDirty() throws {
        let name = "ccp.notes.migstranded.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        store.set(storedJSON(key: "pads", id: padID, text: "after"), forKey: "scratchpadDocument")
        store.set(try JSONEncoder().encode([padID.uuidString: PadSyncBase.fixture("before")]),
                  forKey: "scratchpadCraftBases")
        store.set(try JSONEncoder().encode([padID.uuidString: "doc1"]),
                  forKey: "scratchpadCraftDocuments")
        store.set(try JSONEncoder().encode([padID.uuidString: "Note 1"]),
                  forKey: "scratchpadCraftTitles")

        let adapter = notesAdapter(store, dir: freshNotesDirectory())

        XCTAssertTrue(adapter.isPushDirty(padID),
                      "the unconfirmed content migrates dirty, not clean")
    }
}

/// Synchronous flag for the folder-switch notification.
private final class PostedBox: @unchecked Sendable {
    var posted = false
}
