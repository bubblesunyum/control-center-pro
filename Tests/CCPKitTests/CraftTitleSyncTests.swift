// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

/// Title sync (ccp-o2dh): renames push via page-id PUT, remote renames adopt
/// on pull, both-sides-moved settles last-writer-wins. Reuses the pull file's
/// connection script and the push file's scripted transport.
@MainActor
final class CraftTitleSyncTests: XCTestCase {
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

    /// A mapped pad with converged text and title baselines — the steady
    /// state a rename or a pull finds in production.
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

    /// A single-page fetch carrying `title`: the live shape, with the block
    /// content given as markdowns.
    private func page(_ title: String, _ markdowns: String...,
                      mtime: String? = "2026-09-06T19:00:00Z") -> ScriptedTransport.Script {
        let content = markdowns.enumerated()
            .map { "{\"id\":\"block-\($0.offset)\",\"markdown\":\"\($0.element)\",\"type\":\"text\"}" }
            .joined(separator: ",")
        let metadata = mtime.map { ",\"metadata\":{\"lastModifiedAt\":\"\($0)\"}" } ?? ""
        return ScriptedTransport.Script(statusCode: 200, json: """
            {"id":"doc1","type":"page","markdown":"\(title)"\(metadata),"content":[\(content)]}
            """)
    }

    private func titleEcho(_ title: String) -> ScriptedTransport.Script {
        ScriptedTransport.Script(statusCode: 200, json: """
            {"items":[{"id":"doc1","type":"page","markdown":"\(title)","content":[]}]}
            """)
    }

    /// The trash listing every pull reads between the clock and the fetch.
    /// Empty here; deletion tests live with the pull suite.
    private func trash() -> ScriptedTransport.Script {
        ScriptedTransport.Script(statusCode: 200, json: "{\"items\":[]}")
    }

    func testRenamePushesTitleAlone() async throws {
        let name = "ccp.title.push.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([trash(), titleEcho("Renamed")])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")

        adapter.renameNote(id, to: "Renamed")
        XCTAssertTrue(adapter.isPushDirty(id), "a rename dirties like an edit")
        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 2, "sweep plus one title PUT, no block writes")
        XCTAssertEqual(transport.requests[1].httpMethod, "PUT")
        XCTAssertTrue(transport.requests[1].url?.absoluteString.hasSuffix("/blocks") ?? false)
        let body = try transport.jsonBody(of: 1)
        XCTAssertEqual(body["blocks"] as? [[String: String]],
                       [["id": "doc1", "markdown": "Renamed"]])
        XCTAssertEqual(adapter.syncedTitle(for: id), "Renamed")
        XCTAssertFalse(adapter.isPushDirty(id))
        XCTAssertEqual(adapter.text, "one", "a title push never touches the text")
        XCTAssertEqual(adapter.sidecar(for: id).entries.map(\.id), ["block-0"])
    }

    func testFailedTitlePutKeepsTheBaselineAndTheDirtyBit() async throws {
        let name = "ccp.title.fail.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([ScriptedTransport.Script(statusCode: 500, json: "{}")])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")

        adapter.renameNote(id, to: "Renamed")
        await adapter.flushCraftPush()

        XCTAssertTrue(adapter.isPushDirty(id), "a failed rename retries like a failed edit")
        XCTAssertEqual(adapter.syncedTitle(for: id), "Note 1", "unconfirmed titles record nothing")
        XCTAssertEqual(adapter.selectedNoteName, "Renamed", "the pad keeps its name")
    }

    func testRenameOfUnmappedPadProvisionsWithTheNewName() async throws {
        let name = "ccp.title.provision.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([
            .init(statusCode: 200, json: """
                {"items":[{"id":"doc-new","title":"My Pad","clickableLink":"craftdocs://open?x=y"}]}
                """),
            .init(statusCode: 200, json: """
                {"items":[{"id":"b1","markdown":"hello"}]}
                """),
        ])
        let adapter = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)

        adapter.renameNote(id, to: "My Pad")
        adapter.text = "hello"
        await adapter.flushCraftPush()

        XCTAssertEqual(adapter.craftDocumentID(for: id), "doc-new")
        XCTAssertEqual(transport.requests.count, 2, "create plus content post — no rename PUT")
        XCTAssertEqual(transport.requests[0].httpMethod, "POST")
        XCTAssertTrue(transport.requests[0].url?.absoluteString.hasSuffix("/documents") ?? false)
        let create = try transport.jsonBody(of: 0)
        XCTAssertEqual((create["documents"] as? [[String: String]])?.first?["title"], "My Pad")
        XCTAssertEqual(adapter.syncedTitle(for: id), "My Pad", "born named means born converged")
        XCTAssertFalse(adapter.isPushDirty(id))
    }

    func testPullAdoptsARemoteRename() async throws {
        let name = "ccp.title.adopt.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), page("Taken", "one")])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")

        await adapter.pullAll()

        XCTAssertEqual(transport.requests.count, 3, "clock, trash plus fetch, no writes")
        XCTAssertEqual(adapter.selectedNoteName, "Taken")
        XCTAssertEqual(adapter.syncedTitle(for: id), "Taken")
        XCTAssertFalse(adapter.isPushDirty(id), "an adoption must not echo back")
        XCTAssertNotNil(adapter.syncedAt(for: id))
    }

    func testPullPushesALocalRenameWhenRemoteStoodStill() async throws {
        let name = "ccp.title.localwins.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), page("Note 1", "one"), trash(), titleEcho("Mine")])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")
        adapter.renameNote(id, to: "Mine")

        await adapter.pullAll()

        // Content converged and cleared the bit; the still-dirty title re-adds it.
        XCTAssertEqual(adapter.selectedNoteName, "Mine", "local renames stand")
        XCTAssertTrue(adapter.isPushDirty(id))

        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 5, "clock, trash, fetch, sweep, title PUT")
        let body = try transport.jsonBody(of: 4)
        XCTAssertEqual(body["blocks"] as? [[String: String]],
                       [["id": "doc1", "markdown": "Mine"]])
        XCTAssertEqual(adapter.syncedTitle(for: id), "Mine")
        XCTAssertFalse(adapter.isPushDirty(id))
    }

    func testBothRenamedRemoteNewerAdopts() async throws {
        let name = "ccp.title.lwwremote.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), page("Theirs", "one")])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")
        adapter.renameNote(id, to: "Mine")
        adapter.storeTitleRenameDate(ISO8601DateFormatter().date(from: "2020-01-01T00:00:00Z"), for: id)

        await adapter.pullAll()

        XCTAssertEqual(adapter.selectedNoteName, "Theirs", "the newer rename wins")
        XCTAssertEqual(adapter.syncedTitle(for: id), "Theirs")
        XCTAssertFalse(adapter.isPushDirty(id))
    }

    func testBothRenamedLocalNewerPushes() async throws {
        let name = "ccp.title.lwwlocal.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([
            connection,
            trash(),
            page("Theirs", "one", mtime: "2020-01-01T00:00:00Z"),
            trash(),
            titleEcho("Mine"),
        ])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")
        adapter.renameNote(id, to: "Mine")

        await adapter.pullAll()

        XCTAssertEqual(adapter.selectedNoteName, "Mine", "the newer rename wins")
        XCTAssertTrue(adapter.isPushDirty(id))

        await adapter.flushCraftPush()
        XCTAssertEqual(adapter.syncedTitle(for: id), "Mine")
        XCTAssertFalse(adapter.isPushDirty(id))
    }

    func testBothRenamedTieBreaksLocal() async throws {
        let name = "ccp.title.tie.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let moment = "2026-09-06T19:00:00Z"
        let transport = ScriptedTransport([connection, trash(), page("Theirs", "one", mtime: moment)])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")
        adapter.renameNote(id, to: "Mine")
        adapter.storeTitleRenameDate(ISO8601DateFormatter().date(from: moment), for: id)

        await adapter.pullAll()

        XCTAssertEqual(adapter.selectedNoteName, "Mine", "ties break local, never under typing hands")
        XCTAssertTrue(adapter.isPushDirty(id))
    }

    func testLegacyMappingWithoutBaselineRecordsAndPushesLocal() async throws {
        // Mappings from before title sync carry no baseline: the first pull
        // records Craft's title, and a differing pad name pushes local —
        // pad wins, per the design on ccp-o2dh.
        let name = "ccp.title.legacy.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), page("Craft Title", "mine"), trash(), titleEcho("Note 1")])
        let adapter = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = "mine"
        adapter.storeSidecar(BlockSidecar(entries: [
            BlockSidecarEntry(id: "block-0",
                              fingerprint: BlockSidecar.fingerprint("mine")),
        ]), for: id)
        adapter.setCraftDocumentID("doc1", for: id)
        XCTAssertNil(adapter.syncedTitle(for: id))

        await adapter.pullAll()

        XCTAssertEqual(adapter.syncedTitle(for: id), "Craft Title", "Craft's title is the record")
        XCTAssertEqual(adapter.selectedNoteName, "Note 1", "the pad stands until the push")
        XCTAssertTrue(adapter.isPushDirty(id))
        XCTAssertEqual(adapter.conflicts(for: id).map(\.slices),
                       [["Craft title “Craft Title” was replaced by “Note 1”"]],
                       "the overwritten Craft rename leaves a trace to find it by")

        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 5, "clock, trash, fetch, sweep, title PUT")
        let body = try transport.jsonBody(of: 4)
        XCTAssertEqual(body["blocks"] as? [[String: String]],
                       [["id": "doc1", "markdown": "Note 1"]])
        XCTAssertEqual(adapter.syncedTitle(for: id), "Note 1")
        XCTAssertFalse(adapter.isPushDirty(id))
    }

    func testEmptyRemoteTitleAdoptsNothing() async throws {
        let name = "ccp.title.empty.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), page("", "one")])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")

        await adapter.pullAll()

        XCTAssertEqual(adapter.selectedNoteName, "Note 1")
        XCTAssertEqual(adapter.syncedTitle(for: id), "Note 1", "empty remote titles record nothing")
        XCTAssertFalse(adapter.isPushDirty(id))
    }

    func testNoOpRenameStampsNothing() async throws {
        let name = "ccp.title.noop.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")

        adapter.renameNote(id, to: "Note 1")
        adapter.renameNote(id, to: "  Note 1  ")

        XCTAssertFalse(adapter.isPushDirty(id), "an effectively-unchanged name dirties nothing")
        XCTAssertNil(adapter.titleRenameDate(for: id), "and stamps no LWW clock")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTitleFailureDoesNotStarveTheContentLegs() async throws {
        let name = "ccp.title.headline.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([
            trash(),
            ScriptedTransport.Script(statusCode: 500, json: "{}"),
            .init(statusCode: 200, json: """
                {"items":[{"id":"block-0","markdown":"TWO!"}]}
                """),
        ])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")
        adapter.renameNote(id, to: "Renamed")
        adapter.text = "TWO"

        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 3, "sweep, failed title PUT, content PUT still attempts")
        XCTAssertEqual(adapter.sidecar(for: id).entries[0].fingerprint,
                       BlockSidecar.fingerprint("TWO!"), "the content leg lands")
        XCTAssertEqual(adapter.syncedTitle(for: id), "Note 1", "the failed title records nothing")
        XCTAssertTrue(adapter.isPushDirty(id), "the rename retries next round")
    }

    func testDeleteMidPushStoresNothing() async throws {
        let name = "ccp.title.middelete.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([trash(), titleEcho("Renamed")])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")
        adapter.createNote()
        adapter.renameNote(id, to: "Renamed")
        transport.onRequest = {
            await MainActor.run { _ = adapter.deleteNote(id) }
        }

        await adapter.flushCraftPush()

        XCTAssertNil(adapter.craftDocumentID(for: id))
        XCTAssertEqual(adapter.sidecar(for: id).entries, [], "no resurrection for a dead UUID")
        XCTAssertNil(adapter.syncedTitle(for: id))
    }

    func testTitleLessFetchStrandsNoLocalRename() async throws {
        // Envelope-shaped fetches carry no title: the content decision may
        // clear the bit, but a known-local rename re-asserts it.
        let name = "ccp.title.envelope.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), .init(statusCode: 200, json: """
            {"items":[{"id":"block-0","markdown":"one"}]}
            """), trash(), titleEcho("Mine")])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")
        adapter.renameNote(id, to: "Mine")

        await adapter.pullAll()

        XCTAssertEqual(adapter.selectedNoteName, "Mine")
        XCTAssertTrue(adapter.isPushDirty(id), "the rename survives a title-less pull")

        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 5, "clock, trash, fetch, sweep, title PUT")
        XCTAssertEqual(adapter.syncedTitle(for: id), "Mine")
        XCTAssertFalse(adapter.isPushDirty(id))
    }
}
