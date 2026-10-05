// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

/// The local guards: a file deleted or zeroed under us quarantines its pad
/// instead of emptying it (ccp-zm7f), an empty snapshot refuses to restore,
/// and paused sync moves nothing at the apply layer either (ccp-18rb).
@MainActor
final class NotesLocalGuardTests: XCTestCase {
    private let base = URL(string: "https://connect.craft.do/links/test/api/v1")!

    private func defaults(_ name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func localAdapter(_ store: UserDefaults, dir: URL) -> NotesAdapter {
        let adapter = NotesAdapter(defaults: store, defaultName: "Note", notesDirectory: dir,
                                   destination: CraftNoteDestination(defaults: store))
        adapter.craftCredentialUnavailable = true
        return adapter
    }

    /// Paused sync with everything else live: a fake credential, scripted
    /// transport and a mapped pad — the flag alone must hold every round.
    private func pausedAdapter(_ store: UserDefaults, dir: URL,
                               destination: CraftNoteDestination,
                               transport: ScriptedTransport) -> NotesAdapter {
        let adapter = NotesAdapter(defaults: store, defaultName: "Note", notesDirectory: dir,
                                   destination: destination)
        adapter.craftCredentialUnavailable = false
        adapter.craftTransport = transport
        adapter.craftBaseURLOverride = base
        return adapter
    }

    private func files(in dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
    }

    private func fileExists(_ name: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    // MARK: - Quarantine on missing files (ccp-zm7f)

    func testMissingFileLoadsQuarantinedAndDeactivateWritesNothing() throws {
        let name = "ccp.guard.missing.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let dir = freshNotesDirectory()
        let first = localAdapter(store, dir: dir)
        let id = try XCTUnwrap(first.selectedNoteID)
        first.text = "kept"
        first.deactivate()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Note 1.md"))

        let second = localAdapter(store, dir: dir)

        XCTAssertEqual(second.notes.count, 1, "the tab survives its missing file")
        XCTAssertEqual(second.text, "", "with nothing to recover, the text reads empty")
        XCTAssertTrue(second.isQuarantined(id), "but the pad loads unsaved, not confirmed")
        second.deactivate()

        XCTAssertFalse(fileExists("Note 1.md", in: dir), "closing writes nothing for it")
        XCTAssertEqual(localAdapter(store, dir: dir).notes.count, 1,
                       "and the tab is still there on the next launch")
    }

    func testZeroedFileLoadsQuarantinedUntilRetyped() throws {
        let name = "ccp.guard.zeroed.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let dir = freshNotesDirectory()
        let first = localAdapter(store, dir: dir)
        let id = try XCTUnwrap(first.selectedNoteID)
        first.text = "kept"
        first.deactivate()
        try "".write(to: dir.appendingPathComponent("Note 1.md"), atomically: true, encoding: .utf8)

        let second = localAdapter(store, dir: dir)
        XCTAssertTrue(second.isQuarantined(id), "a zeroed file quarantines like a missing one")

        second.text = "retyped"
        second.deactivate()

        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Note 1.md"), encoding: .utf8),
                       "retyped", "the explicit retype heals the pad and persists")
        let third = localAdapter(store, dir: dir)
        XCTAssertEqual(third.text, "retyped")
        XCTAssertFalse(third.isQuarantined(id))
    }

    /// The panel was open on saved text; the file vanished underneath. The
    /// reopen reload keeps the in-memory text and quarantines the pad —
    /// it must not clobber what the file no longer holds.
    func testActivateReloadKeepsInMemoryTextWhenFileVanishes() throws {
        let name = "ccp.guard.reload.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let dir = freshNotesDirectory()
        let adapter = localAdapter(store, dir: dir)
        let id = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = "live"
        adapter.deactivate()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Note 1.md"))

        adapter.activate()

        XCTAssertEqual(adapter.text, "live", "the reload never clobbers in-memory text")
        XCTAssertTrue(adapter.isQuarantined(id))
        adapter.deactivate()
        XCTAssertFalse(fileExists("Note 1.md", in: dir), "and closing still writes nothing for it")
    }

    func testCloseTabHidesQuarantinedPadInsteadOfDeleting() throws {
        let name = "ccp.guard.close.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let dir = freshNotesDirectory()
        let first = localAdapter(store, dir: dir)
        first.text = "kept"
        first.deactivate()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Note 1.md"))
        let second = localAdapter(store, dir: dir)
        let id = try XCTUnwrap(second.selectedNoteID)
        XCTAssertTrue(second.isQuarantined(id))

        XCTAssertTrue(second.closeTab(id))

        XCTAssertTrue(second.notes.map(\.id).contains(id), "a quarantined pad is hidden, never deleted")
        XCTAssertEqual(second.closedNoteIDs, [id])
        XCTAssertFalse(fileExists("Note 1.md", in: dir), "hiding recreates nothing either")
    }

    // MARK: - Empty snapshot restore (ccp-zm7f)

    func testRestoreSnapshotRefusesEmptyMarkdown() throws {
        let name = "ccp.guard.snapshot.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let adapter = localAdapter(store, dir: freshNotesDirectory())
        let id = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = "current"
        adapter.recordSnapshot(markdown: "", reason: .pull, date: nil, for: id)
        let emptyID = try XCTUnwrap(adapter.snapshots(for: id).first?.id)

        adapter.restoreSnapshot(emptyID, for: id)

        XCTAssertEqual(adapter.text, "current", "restoring an empty snapshot is refused")
        XCTAssertEqual(adapter.snapshots(for: id).count, 1, "and the refusal snapshots nothing either")

        adapter.recordSnapshot(markdown: "earlier", reason: .pull, date: nil, for: id)
        let earlierID = try XCTUnwrap(adapter.snapshots(for: id).first(where: { $0.markdown == "earlier" })?.id)
        adapter.text = "later"
        adapter.restoreSnapshot(earlierID, for: id)
        XCTAssertEqual(adapter.text, "earlier", "a non-empty restore still lands")
    }

    // MARK: - Paused sync moves nothing (ccp-18rb)

    func testPausedSyncPerformsZeroTransport() async throws {
        XCTAssertTrue(NotesAdapter.craftSyncDisabled, "these tests prove the paused flag")
        let name = "ccp.guard.paused.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let destination = CraftNoteDestination(defaults: store)
        let transport = ScriptedTransport([])
        let adapter = pausedAdapter(store, dir: freshNotesDirectory(),
                                    destination: destination, transport: transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)
        destination.setCraftDocumentID("doc1", for: id)
        adapter.text = "mapped edit"

        adapter.activate()
        await adapter.flushCraftPush()
        await adapter.pullAll()
        adapter.deactivate()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(transport.requests.isEmpty, "no round starts while paused, credential or not")
        XCTAssertFalse(adapter.isSyncVerified, "and no round verifies either")
        XCTAssertEqual(adapter.syncStatus, .localOnly)
    }

    func testPausedApplyLayerIsNoOp() throws {
        XCTAssertTrue(NotesAdapter.craftSyncDisabled, "these tests prove the paused flag")
        let name = "ccp.guard.apply.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let destination = CraftNoteDestination(defaults: store)
        let adapter = pausedAdapter(store, dir: freshNotesDirectory(),
                                    destination: destination, transport: ScriptedTransport([]))
        let id = try XCTUnwrap(adapter.selectedNoteID)
        destination.setCraftDocumentID("doc1", for: id)
        destination.storeBase(.fixture("base"), for: id)
        destination.storeSyncedTitle("Note 1", for: id)
        adapter.text = "local edit"

        adapter.adoptRemote(padID: id, text: "remote", base: nil,
                            snapshotReason: .pull, snapshotDate: nil)
        XCTAssertEqual(adapter.text, "local edit", "a pulled text must not land while paused")
        XCTAssertTrue(adapter.snapshots(for: id).isEmpty, "nor snapshot on the way in")

        adapter.adoptTitle(padID: id, title: "Elsewhere", date: nil)
        XCTAssertEqual(adapter.selectedNoteName, "Note 1")

        adapter.reconcileTitle(padID: id, remoteTitle: "Elsewhere",
                               remoteModified: Date(), serverTime: nil)
        XCTAssertEqual(adapter.selectedNoteName, "Note 1", "titles stay local while paused")
        XCTAssertTrue(adapter.isPushDirty(id), "without dirtying or pushing either")

        // Unconfirmed edits would unmap; a converged pad would delete. Both
        // stand while paused.
        adapter.settleTrashedPad(id)
        XCTAssertTrue(adapter.isPushDirty(id), "the unconfirmed pad keeps its mapping and its bit")
        adapter.createNote()
        let convergedID = try XCTUnwrap(adapter.selectedNoteID)
        destination.setCraftDocumentID("doc2", for: convergedID)
        destination.storeBase(.fixture(""), for: convergedID)
        destination.storeSyncedTitle(adapter.selectedNoteName, for: convergedID)
        adapter.settleTrashedPad(convergedID)
        XCTAssertEqual(adapter.notes.count, 2, "the converged pad is not deleted while paused")
    }

    func testPausedReadOnlyBlocksAndPinnedRestoreStandDown() throws {
        XCTAssertTrue(NotesAdapter.craftSyncDisabled, "these tests prove the paused flag")
        let name = "ccp.guard.pinned.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let destination = CraftNoteDestination(defaults: store)
        let adapter = pausedAdapter(store, dir: freshNotesDirectory(),
                                    destination: destination, transport: ScriptedTransport([]))
        let id = try XCTUnwrap(adapter.selectedNoteID)
        destination.storeBase(.fixture("pinned", writable: false), for: id)

        XCTAssertFalse(adapter.containsReadOnlyBlocks, "a stale base must not mark the UI")

        adapter.text = "changed"
        let restored = adapter.restorePinnedBlocks(padID: id, base: .fixture("pinned", writable: false),
                                                   padText: "changed")
        XCTAssertNil(restored, "a stale base must not rewrite the pad")
        XCTAssertEqual(adapter.text, "changed")
        XCTAssertTrue(adapter.snapshots(for: id).isEmpty)
    }
}
