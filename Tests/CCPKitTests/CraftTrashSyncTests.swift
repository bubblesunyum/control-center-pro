// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

/// Remote deletes win (ccp-5fom): a doc Craft trashed deletes its pad —
/// text, tab, mapping and traces — on the next pull, and the editor holds
/// keystrokes until that pull verifies. Reuses the push file's scripted
/// transport.
@MainActor
final class CraftTrashSyncTests: XCTestCase {
    private let base = URL(string: "https://connect.craft.do/links/test/api/v1")!
    private let connection = ScriptedTransport.Script(statusCode: 200, json: """
        {"space":{"name":"Test"},"utc":{"time":"2026-09-06T19:00:00Z"}}
        """)

    private func defaults(_ name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func adapter(_ store: UserDefaults, _ transport: ScriptedTransport) -> NotesAdapter {
        let adapter = NotesAdapter(defaults: store, defaultName: "Note")
        adapter.craftTransport = transport
        adapter.craftBaseURLOverride = base
        return adapter
    }

    /// A mapped pad holding `text`, converged and clean — the steady state a
    /// pull finds in production. The scrub push is a no-op (sidecar already
    /// describes the text), so it spends no scripts.
    @discardableResult
    private func steadyPad(_ adapter: NotesAdapter, text: String) async throws -> UUID {
        let id = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = text
        adapter.storeSidecar(BlockSidecar(entries: [text].enumerated().map { index, markdown in
            BlockSidecarEntry(id: "block-\(index)",
                              fingerprint: BlockSidecar.fingerprint(markdown))
        }), for: id)
        adapter.setCraftDocumentID("doc1", for: id)
        adapter.storeSyncedTitle(adapter.selectedNoteName, for: id)
        await adapter.flushCraftPush()
        XCTAssertFalse(adapter.isPushDirty(id), "steady state starts clean")
        return id
    }

    private func blocks(_ json: String) -> ScriptedTransport.Script {
        ScriptedTransport.Script(statusCode: 200, json: json)
    }

    /// The trash listing: empty, or naming trashed doc ids.
    private func trash(_ ids: String...) -> ScriptedTransport.Script {
        let items = ids.map { "{\"id\":\"\($0)\"}" }.joined(separator: ",")
        return ScriptedTransport.Script(statusCode: 200, json: "{\"items\":[\(items)]}")
    }

    func testTrashedDocumentIDsListsTrash() async throws {
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"items":[{"id":"a","title":"Gone"},{"id":"b","title":"Also gone"}]}
            """)])
        let client = CraftClient(baseURL: base, transport: transport)

        let trashed = try await client.trashedDocumentIDs()
        XCTAssertEqual(trashed, ["a", "b"])
        let url = try XCTUnwrap(transport.requests[0].url)
        XCTAssertEqual(url.lastPathComponent, "documents")
        let query = Dictionary(
            try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                .map { ($0.name, $0.value) },
            uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(query["location"], "trash")
    }

    func testTrashedDocumentIDsThrowsOnFailure() async throws {
        for json in ["{}", "{\"items\":[{\"noid\":1}]}"] {
            let transport = ScriptedTransport([.init(statusCode: 200, json: json)])
            let client = CraftClient(baseURL: base, transport: transport)

            do {
                _ = try await client.trashedDocumentIDs()
                XCTFail("an unreadable trash read must throw, never read as empty — for \(json)")
            } catch let error as CraftClientError {
                XCTAssertEqual(error, .unreachable(statusCode: 200))
            }
        }
        let failed = ScriptedTransport([.init(statusCode: 500, json: "{}")])
        do {
            _ = try await CraftClient(baseURL: base, transport: failed).trashedDocumentIDs()
            XCTFail("a failed trash read must throw, never read as empty")
        } catch let error as CraftClientError {
            XCTAssertEqual(error, .unreachable(statusCode: 500))
        }
    }

    func testTrashedDocDeletesItsPad() async throws {
        let name = "ccp.trash.delete.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash("doc1")])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")
        adapter.createNote()
        let survivor = try XCTUnwrap(adapter.selectedNoteID)

        await adapter.pullAll()

        XCTAssertFalse(adapter.notes.contains(where: { $0.id == id }), "the trashed pad is gone")
        XCTAssertEqual(adapter.notes.map(\.id), [survivor])
        XCTAssertNil(adapter.craftDocumentID(for: id), "the mapping leaves with the note")
        XCTAssertEqual(adapter.sidecar(for: id).entries, [])
        XCTAssertNil(adapter.syncedTitle(for: id))
        XCTAssertFalse(adapter.isPushDirty(id))
        XCTAssertTrue(adapter.isSyncVerified, "a proving pull unlocks")
    }

    func testTrashedClosedNoteLeavesTheOverflowMenu() async throws {
        let name = "ccp.trash.menu.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash("doc1")])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")
        XCTAssertTrue(adapter.closeTab(id))
        XCTAssertEqual(adapter.restorableClosedNotes.map(\.id), [id], "hidden with text lists first")

        await adapter.pullAll()

        XCTAssertTrue(adapter.restorableClosedNotes.isEmpty, "the trashed doc leaves the menu")
        XCTAssertTrue(adapter.closedNotes.isEmpty)
        XCTAssertFalse(adapter.notes.contains(where: { $0.id == id }))
    }

    func testFailedTrashReadDeletesNothing() async throws {
        let name = "ccp.trash.failure.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection,
                                           ScriptedTransport.Script(statusCode: 500, json: "{}")])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")

        await adapter.pullAll()

        XCTAssertTrue(adapter.notes.contains(where: { $0.id == id }), "failure skips the pass")
        XCTAssertEqual(adapter.craftDocumentID(for: id), "doc1", "the mapping stands")
        XCTAssertTrue(adapter.isSyncVerified, "the clock still verified")
    }

    func testFetch404OutsideTrashKeepsThePad() async throws {
        // A fetch 404 on a doc the trash does not name is a scope problem,
        // never a delete — only membership deletes.
        let name = "ccp.trash.404.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(),
                                           ScriptedTransport.Script(statusCode: 404, json: "{}")])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")

        await adapter.pullAll()

        XCTAssertTrue(adapter.notes.contains(where: { $0.id == id }))
        XCTAssertEqual(adapter.craftDocumentID(for: id), "doc1")
    }

    func testDirtyTrashedPadKeepsItsTextAndGoesLocalOnly() async throws {
        // The only copy of unpushed edits is here: deleting would destroy
        // text neither side holds, so the pad unmaps and stays instead —
        // while its clean neighbour still deletes.
        let name = "ccp.trash.dirty.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash("doc1"), blocks("""
            {"items":[{"id":"block-0","markdown":"two"}]}
            """)])
        let adapter = adapter(store, transport)
        let doomed = try await steadyPad(adapter, text: "one")
        adapter.createNote()
        let clean = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = "two"
        adapter.storeSidecar(BlockSidecar(entries: [
            BlockSidecarEntry(id: "block-0", fingerprint: BlockSidecar.fingerprint("two")),
        ]), for: clean)
        adapter.setCraftDocumentID("doc2", for: clean)
        adapter.storeSyncedTitle(adapter.selectedNoteName, for: clean)
        await adapter.flushCraftPush()
        adapter.selectNote(doomed)
        adapter.text = "one edited"

        await adapter.pullAll()

        XCTAssertEqual(adapter.notes.first(where: { $0.id == doomed })?.text, "one edited")
        XCTAssertNil(adapter.craftDocumentID(for: doomed), "unconfirmed pads unmap, never delete")
        XCTAssertEqual(adapter.sidecar(for: doomed).entries, [])
        XCTAssertFalse(adapter.isPushDirty(doomed), "local-only pads owe no push")
        XCTAssertEqual(adapter.craftDocumentID(for: clean), "doc2", "the clean neighbour stands")
        XCTAssertEqual(adapter.notes.count, 2)
    }

    func testSoleTrashedPadMintsAFreshNote() async throws {
        // deleteNote refuses the last doc; a sole trashed pad still goes,
        // with a blank note standing where it was.
        let name = "ccp.trash.sole.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash("doc1")])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")

        await adapter.pullAll()

        XCTAssertFalse(adapter.notes.contains(where: { $0.id == id }))
        XCTAssertEqual(adapter.notes.count, 1)
        XCTAssertEqual(adapter.text, "", "a fresh blank stands in")
        XCTAssertNil(adapter.craftDocumentID(for: id))
    }

    func testPushSettlesTrashedPadsBeforeWriting() async throws {
        // A doc trashed mid-session still answers writes with 200: the push
        // must settle first, or local text ends up living only in the trash.
        let name = "ccp.trash.pushsweep.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), blocks("""
            {"items":[{"id":"block-0","markdown":"one"}]}
            """), trash("doc1")])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")

        await adapter.pullAll()
        XCTAssertEqual(adapter.syncStatus, .saved)

        adapter.text = "one edited"
        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 4, "clock, trash, fetch, sweep — nothing written")
        XCTAssertEqual(adapter.text, "one edited", "the text stands")
        XCTAssertNil(adapter.craftDocumentID(for: id), "unconfirmed pads unmap")
        XCTAssertFalse(adapter.isPushDirty(id))
        XCTAssertEqual(adapter.syncStatus, .localOnly, "unmapped pads read local-only, never saved")
    }

    func testCredentialedAdapterIsLockedUntilThePull() async throws {
        let name = "ccp.trash.gate.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let adapter = adapter(store, ScriptedTransport([]))

        XCTAssertTrue(adapter.hasCraftCredential)
        XCTAssertFalse(adapter.isEditable, "unverified pads hold keystrokes")
        XCTAssertEqual(adapter.syncStatus, .syncing)
    }

    func testSuccessfulPullUnlocksAsSaved() async throws {
        let name = "ccp.trash.unlock.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), blocks("""
            {"items":[{"id":"block-0","markdown":"one"}]}
            """)])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")
        XCTAssertFalse(adapter.isEditable, "no pull yet, no typing")

        await adapter.pullAll()

        XCTAssertTrue(adapter.isEditable)
        XCTAssertEqual(adapter.syncStatus, .saved)

        adapter.text = "one edited"
        XCTAssertTrue(adapter.isEditable, "verified pads stay editable")
        XCTAssertEqual(adapter.syncStatus, .unsavedChanges)
        XCTAssertTrue(adapter.isPushDirty(id))
    }

    func testFailedCheckLocksAsOffline() async throws {
        let name = "ccp.trash.offline.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([ScriptedTransport.Script(statusCode: 500, json: "{}")])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")

        await adapter.pullAll()

        XCTAssertFalse(adapter.isEditable)
        XCTAssertEqual(adapter.syncStatus, .offline)
        XCTAssertTrue(adapter.notes.contains(where: { $0.id == id }), "offline deletes nothing")
    }

    func testLocalOnlyPadsStayEditable() throws {
        let name = "ccp.trash.local.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        let adapter = NotesAdapter(defaults: store, defaultName: "Note")
        adapter.craftCredentialUnavailable = true

        XCTAssertFalse(adapter.hasCraftCredential)
        XCTAssertTrue(adapter.isEditable, "no credential means local-only notes")
        XCTAssertEqual(adapter.syncStatus, .localOnly)
    }
}
