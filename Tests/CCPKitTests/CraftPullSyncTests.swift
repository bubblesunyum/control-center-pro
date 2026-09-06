// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

/// The read half: GET shape, tree flattening, and the adapter's adopt /
/// stash-and-adopt. Reuses the push file's scripted transport.
final class CraftPullWireTests: XCTestCase {
    private let base = URL(string: "https://connect.craft.do/links/test/api/v1")!

    private func client(_ transport: ScriptedTransport) -> CraftClient {
        CraftClient(baseURL: base, transport: transport)
    }

    func testFetchSendsDocumentQueryAndFlattensTheTreeInOrder() async throws {
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"items":[{"id":"doc1","type":"page","content":[
              {"id":"a","markdown":"one","type":"text"},
              {"id":"sub","content":[
                {"id":"b","markdown":"two","type":"text"}]},
              {"id":"img","type":"image"}
            ]}]}
            """)])
        let blocks = try await client(transport).fetchDocument(documentID: "doc1").blocks

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].httpMethod, "GET")
        let url = try XCTUnwrap(transport.requests[0].url)
        XCTAssertEqual(url.lastPathComponent, "blocks")
        let query = Dictionary(
            try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                .map { ($0.name, $0.value) },
            uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(query["id"], "doc1")
        XCTAssertEqual(query["maxDepth"], "-1")

        XCTAssertEqual(blocks.map(\.id), ["a", "b", "img"])
        XCTAssertEqual(blocks.map(\.markdown), ["one", "two", nil])
    }

    func testFetchParsesBlocksEnvelopeAndBareArraysToo() async throws {
        for json in ["{\"blocks\":[{\"id\":\"a\",\"markdown\":\"one\"}]}",
                     "[{\"id\":\"a\",\"markdown\":\"one\"}]"] {
            let transport = ScriptedTransport([.init(statusCode: 200, json: json)])
            let blocks = try await client(transport).fetchDocument(documentID: "doc1").blocks
            XCTAssertEqual(blocks, [FetchedBlock(id: "a", markdown: "one")], "for \(json)")
        }
    }

    func testFetchParsesSinglePageObjectSkippingTheTitle() async throws {
        // The live shape (ccp-pn8g): GET /blocks returns the page itself,
        // whose markdown is the document title — position, not text. The
        // title rides the fetch for the title sync (ccp-o2dh) instead.
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"id":"doc1","type":"page","markdown":"playground","content":[
              {"id":"a","markdown":"one","type":"text"},
              {"id":"img","type":"image"},
              {"id":"sub","content":[
                {"id":"b","markdown":"two","type":"text"}]}
            ]}
            """)])
        let fetched = try await client(transport).fetchDocument(documentID: "doc1")

        XCTAssertEqual(fetched.title, "playground")
        XCTAssertNil(fetched.modifiedAt, "no metadata fetched, no mtime")
        XCTAssertEqual(fetched.blocks.map(\.id), ["a", "img", "b"])
        XCTAssertEqual(fetched.blocks.map(\.markdown), ["one", nil, "two"])
    }

    func testFetchParsesPageRootMtimeFromMetadata() async throws {
        // The title sync's remote clock (ccp-o2dh): lastModifiedAt wins,
        // createdAt stands in when it is missing, garbage reads as unknown.
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"id":"doc1","type":"page","markdown":"playground",
             "metadata":{"createdAt":"2026-09-06T18:00:00Z",
                         "lastModifiedAt":"2026-09-06T19:05:37.034Z"},
             "content":[{"id":"a","markdown":"one","type":"text"}]}
            """)])
        let fetched = try await client(transport).fetchDocument(documentID: "doc1")

        XCTAssertEqual(fetched.title, "playground")
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(fetched.modifiedAt, fractional.date(from: "2026-09-06T19:05:37.034Z"))
        XCTAssertEqual(fetched.blocks.map(\.id), ["a"])
    }

    func testFetchIgnoresCreatedAtAndToleratesGarbageMtime() async throws {
        // createdAt is the document's birth, not the title's: only
        // lastModifiedAt reads as the remote clock (ccp-o2dh review).
        for metadata in ["\"createdAt\":\"2026-09-06T18:00:00Z\"",
                         "\"lastModifiedAt\":\"not a date\"",
                         "\"createdAt\":\"2026-09-06T18:00:00Z\",\"lastModifiedAt\":\"not a date\""] {
            let transport = ScriptedTransport([.init(statusCode: 200, json: """
                {"id":"doc1","type":"page","markdown":"playground",
                 "metadata":{\(metadata)},
                 "content":[]}
                """)])
            let fetched = try await client(transport).fetchDocument(documentID: "doc1")
            XCTAssertNil(fetched.modifiedAt, "for \(metadata)")
        }
    }

    func testFetchAsksForMetadataAndEnvelopesCarryNoTitle() async throws {
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"items":[{"id":"a","markdown":"one"}]}
            """)])
        let fetched = try await client(transport).fetchDocument(documentID: "doc1")

        let url = try XCTUnwrap(transport.requests[0].url)
        let query = Dictionary(
            try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                .map { ($0.name, $0.value) },
            uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(query["fetchMetadata"], "true")
        XCTAssertNil(fetched.title, "an envelope names no document")
        XCTAssertNil(fetched.modifiedAt)
        XCTAssertEqual(fetched.blocks, [FetchedBlock(id: "a", markdown: "one")])
    }

    func testFetchEmptyPageIsEmptyRatherThanUnreachable() async throws {
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"id":"doc1","type":"page","markdown":"empty","content":[]}
            """)])
        let blocks = try await client(transport).fetchDocument(documentID: "doc1").blocks

        XCTAssertEqual(blocks, [])
    }

    func testFetchWrappedPageWithTitleSkipsTheTitleToo() async throws {
        for json in ["{\"items\":[{\"id\":\"doc1\",\"type\":\"page\",\"markdown\":\"playground\",\"content\":[{\"id\":\"a\",\"markdown\":\"one\"}]}]}",
                     "[{\"id\":\"doc1\",\"type\":\"page\",\"markdown\":\"playground\",\"content\":[{\"id\":\"a\",\"markdown\":\"one\"}]}]"] {
            let transport = ScriptedTransport([.init(statusCode: 200, json: json)])
            let blocks = try await client(transport).fetchDocument(documentID: "doc1").blocks
            XCTAssertEqual(blocks, [FetchedBlock(id: "a", markdown: "one")], "for \(json)")
        }
    }

    func testFetchContentLessPageIsEmptyAndErrorPayloadStillThrows() async throws {
        let empty = ScriptedTransport([.init(statusCode: 200, json: """
            {"id":"doc1","type":"page","markdown":"empty"}
            """)])
        let emptyBlocks = try await client(empty).fetchDocument(documentID: "doc1").blocks
        XCTAssertEqual(emptyBlocks, [])

        let error = ScriptedTransport([.init(statusCode: 200, json: "{}")])
        do {
            _ = try await client(error).fetchDocument(documentID: "doc1").blocks
            XCTFail("an id-less object must throw")
        } catch let clientError as CraftClientError {
            XCTAssertEqual(clientError, .unreachable(statusCode: 200))
        }
    }

    func testFetchEmptyContentArrayStillPinsPosition() async throws {
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"items":[{"id":"a","markdown":"one"},{"id":"img","type":"image","content":[]}]}
            """)])
        let blocks = try await client(transport).fetchDocument(documentID: "doc1").blocks

        XCTAssertEqual(blocks, [FetchedBlock(id: "a", markdown: "one"),
                                FetchedBlock(id: "img", markdown: nil)])
    }

    func testFetchFailureIsUnreachable() async throws {
        let transport = ScriptedTransport([.init(statusCode: 500, json: "{}")])
        do {
            _ = try await client(transport).fetchDocument(documentID: "doc1").blocks
            XCTFail("a 500 must throw")
        } catch let error as CraftClientError {
            XCTAssertEqual(error, .unreachable(statusCode: 500))
        }
    }
}

/// The adapter half: activate pulls, clean adopts, dirty skips, moved
/// conflicts stash first, and a failed read never touches the pad.
@MainActor
final class CraftPullAdapterTests: XCTestCase {
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

    /// A mapped pad holding `text`, with the sidecar seeded from `seeded`
    /// and the dirty bit scrubbed via a no-op push — the steady state a pull
    /// finds in production.
    @discardableResult
    private func steadyPad(_ adapter: NotesAdapter, text: String,
                           seeded: [String]? = nil) async throws -> UUID {
        let id = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = text
        adapter.storeSidecar(BlockSidecar(entries: (seeded ?? [text]).enumerated().map { index, markdown in
            BlockSidecarEntry(id: "block-\(index)",
                              fingerprint: BlockSidecar.fingerprint(markdown))
        }), for: id)
        adapter.setCraftDocumentID("doc1", for: id)
        // Steady means title-converged too, or the flush below spends a
        // rename PUT and never comes back clean.
        adapter.storeSyncedTitle(adapter.selectedNoteName, for: id)
        await adapter.flushCraftPush()
        XCTAssertFalse(adapter.isPushDirty(id), "steady state starts clean")
        return id
    }

    private func blocks(_ json: String) -> ScriptedTransport.Script {
        ScriptedTransport.Script(statusCode: 200, json: json)
    }

    func testCleanPadAdoptsRemoteEditsAndReseeds() async throws {
        let name = "ccp.pull.adopt.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, blocks("""
            {"items":[{"id":"block-0","markdown":"ONE"}]}
            """)])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")

        await adapter.pullAll()

        XCTAssertEqual(transport.requests.count, 2, "clock plus one fetch, no writes")
        XCTAssertEqual(adapter.text, "ONE")
        XCTAssertEqual(adapter.sidecar(for: id).entries.map(\.id), ["block-0"])
        XCTAssertEqual(adapter.sidecar(for: id).entries[0].fingerprint,
                       BlockSidecar.fingerprint("ONE"))
        XCTAssertNotNil(adapter.syncedAt(for: id))
        XCTAssertFalse(adapter.isPushDirty(id), "adopted text must not re-push")
    }

    func testDirtyPadSkipsWhenRemoteDidNotMove() async throws {
        let name = "ccp.pull.skip.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, blocks("""
            {"items":[{"id":"block-0","markdown":"one"}]}
            """)])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")
        adapter.text = "one edited"
        XCTAssertTrue(adapter.isPushDirty(id))

        await adapter.pullAll()

        XCTAssertEqual(adapter.text, "one edited", "local edits stand")
        XCTAssertEqual(adapter.sidecar(for: id).entries.map(\.id), ["block-0"])
        XCTAssertTrue(adapter.isPushDirty(id), "the push still owns these edits")
        XCTAssertNil(adapter.syncedAt(for: id), "a skip records nothing")
    }

    func testDirtyPadStashesToCraftThenAdoptsOnConflict() async throws {
        let name = "ccp.pull.conflict.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, blocks("""
            {"items":[{"id":"r1","markdown":"theirs"}]}
            """), blocks("""
            {"items":[{"id":"c1","markdown":"# Conflicted copy"},
                       {"id":"c2","markdown":"mine edited"}]}
            """)])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "mine", seeded: ["mine"])
        // Re-pin the seeded id to the remote's: the clash is in the text.
        adapter.storeSidecar(BlockSidecar(entries: [
            BlockSidecarEntry(id: "r1", fingerprint: BlockSidecar.fingerprint("mine")),
        ]), for: id)
        adapter.text = "mine edited"
        XCTAssertTrue(adapter.isPushDirty(id))

        await adapter.pullAll()

        XCTAssertEqual(transport.requests.count, 3, "clock, fetch, stash — no PUT, no DELETE")
        let post = transport.requests[2]
        XCTAssertEqual(post.httpMethod, "POST")
        let body = try transport.jsonBody(of: 2)
        let posted = try XCTUnwrap(body["blocks"] as? [[String: String]])
        XCTAssertEqual(posted.count, 2, "heading plus the local blocks")
        XCTAssertTrue(try XCTUnwrap(posted[0]["markdown"]).hasPrefix("# Conflicted copy"),
                      "the stash is labelled and dated")
        XCTAssertTrue(try XCTUnwrap(posted[0]["markdown"]).contains("2026-09-06"),
                      "dated by the server clock the pull brought")
        XCTAssertEqual(posted[1]["markdown"], "mine edited")
        let position = try XCTUnwrap(body["position"] as? [String: String])
        XCTAssertEqual(position["position"], "after")
        XCTAssertEqual(position["siblingId"], "r1", "the stash appends behind the remote")

        XCTAssertEqual(adapter.text, "theirs", "remote wins after the stash")
        let entries = adapter.sidecar(for: id).entries
        XCTAssertEqual(entries.map(\.id), ["r1", "c1", "c2"])
        XCTAssertTrue(entries[0].isWritable)
        XCTAssertFalse(entries[1].isWritable, "stash pins never ride a push")
        XCTAssertFalse(entries[2].isWritable)
        XCTAssertEqual(adapter.stashIDs(for: id), ["c1", "c2"])
        XCTAssertFalse(adapter.isPushDirty(id))
        XCTAssertNotNil(adapter.syncedAt(for: id))

        let records = adapter.conflicts(for: id)
        XCTAssertEqual(records.count, 1, "the landed stash is listed")
        XCTAssertEqual(records[0].slices, ["mine edited"])
        let clock = ISO8601DateFormatter().date(from: "2026-09-06T19:00:00Z")
        XCTAssertEqual(records[0].date, clock, "dated by the server clock, never the Mac's")
    }

    func testFailedStashPostRecordsNothing() async throws {
        let name = "ccp.pull.stashfail.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, blocks("""
            {"items":[{"id":"r1","markdown":"theirs"}]}
            """), ScriptedTransport.Script(statusCode: 500, json: "{}")])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "mine", seeded: ["mine"])
        adapter.storeSidecar(BlockSidecar(entries: [
            BlockSidecarEntry(id: "r1", fingerprint: BlockSidecar.fingerprint("mine")),
        ]), for: id)
        adapter.text = "mine edited"

        await adapter.pullAll()

        XCTAssertEqual(adapter.conflicts(for: id), [], "a stash that never landed lists nothing")
        XCTAssertEqual(adapter.text, "mine edited")
    }

    func testConflictRecordsCapDismissAndDropWithTheNote() async throws {
        let name = "ccp.pull.records.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let adapter = NotesAdapter(defaults: store, defaultName: "Note")
        let id = try XCTUnwrap(adapter.selectedNoteID)
        XCTAssertEqual(adapter.conflictsVersion, 0)

        for index in 0..<7 {
            adapter.recordConflict(slices: ["v\(index)"], date: nil, for: id)
        }
        XCTAssertEqual(adapter.conflictsVersion, 7, "records publish for the toolbar")
        XCTAssertEqual(adapter.conflicts(for: id).map(\.slices),
                       [["v6"], ["v5"], ["v4"], ["v3"], ["v2"]],
                       "newest first, capped at five")

        let doomed = try XCTUnwrap(adapter.conflicts(for: id).first?.id)
        adapter.dismissConflict(doomed, for: id)
        XCTAssertEqual(adapter.conflictsVersion, 8)
        XCTAssertEqual(adapter.conflicts(for: id).count, 4)
        // Dismissing a stranger changes nothing.
        adapter.dismissConflict(UUID(), for: id)
        XCTAssertEqual(adapter.conflicts(for: id).count, 4)

        adapter.createNote()
        let doomedID = id
        XCTAssertTrue(adapter.deleteNote(doomedID), "two notes, so the delete lands")
        XCTAssertEqual(adapter.conflicts(for: doomedID), [], "records leave with the note")
    }

    func testCloseNoteDropsAllSyncState() async throws {
        let name = "ccp.pull.close.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, blocks("""
            {"items":[{"id":"r1","markdown":"theirs"}]}
            """), blocks("""
            {"items":[{"id":"c1","markdown":"# Conflicted copy"},
                       {"id":"c2","markdown":"mine edited"}]}
            """)])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "mine", seeded: ["mine"])
        adapter.storeSidecar(BlockSidecar(entries: [
            BlockSidecarEntry(id: "r1", fingerprint: BlockSidecar.fingerprint("mine")),
        ]), for: id)
        adapter.text = "mine edited"

        await adapter.pullAll()
        XCTAssertFalse(adapter.conflicts(for: id).isEmpty, "a stash to drop")
        XCTAssertFalse(adapter.stashIDs(for: id).isEmpty)
        XCTAssertNotNil(adapter.syncedAt(for: id))

        adapter.createNote()
        XCTAssertTrue(adapter.deleteNote(id))

        XCTAssertEqual(adapter.conflicts(for: id), [])
        XCTAssertEqual(adapter.stashIDs(for: id), [])
        XCTAssertNil(adapter.syncedAt(for: id))
        XCTAssertEqual(adapter.sidecar(for: id).entries, [])
        XCTAssertNil(adapter.craftDocumentID(for: id))
        XCTAssertNil(adapter.syncedTitle(for: id), "title baselines leave with the note")
        XCTAssertNil(adapter.titleRenameDate(for: id))
    }

    func testFailedFetchLeavesPadSidecarAndDirtyBitAlone() async throws {
        let name = "ccp.pull.failure.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection,
                                           ScriptedTransport.Script(statusCode: 500, json: "{}")])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")
        adapter.text = "one edited"

        await adapter.pullAll()

        XCTAssertEqual(adapter.text, "one edited")
        XCTAssertEqual(adapter.sidecar(for: id).entries.map(\.id), ["block-0"])
        XCTAssertTrue(adapter.isPushDirty(id), "a failed read must not clear unpushed edits")
        XCTAssertNil(adapter.syncedAt(for: id))
    }

    func testHandMappedPadStashesInsteadOfWiping() async throws {
        // The review's wipe: typed text in a freshly mapped pad was never
        // confirmed, so a clean dirty bit must not read as permission.
        let name = "ccp.pull.handmap.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, blocks("""
            {"items":[{"id":"r1","markdown":"theirs"}]}
            """), blocks("""
            {"items":[{"id":"c1","markdown":"# Conflicted copy"},
                       {"id":"c2","markdown":"my notes"}]}
            """)])
        let adapter = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = "my notes"
        adapter.setCraftDocumentID("doc1", for: id)

        await adapter.pullAll()

        XCTAssertEqual(transport.requests.count, 3, "clock, fetch, stash")
        XCTAssertEqual(adapter.text, "theirs")
        let entries = adapter.sidecar(for: id).entries
        XCTAssertEqual(entries.map(\.id), ["r1", "c1", "c2"])
        XCTAssertFalse(entries[1].isWritable)
        XCTAssertFalse(entries[2].isWritable)
    }

    func testKeystrokesDuringTheFetchLandInTheStash() async throws {
        // The race: deciding on pre-fetch text strands mid-fetch keystrokes
        // between the stash and the adopt.
        let name = "ccp.pull.race.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, blocks("""
            {"items":[{"id":"block-0","markdown":"THEIRS"}]}
            """), blocks("""
            {"items":[{"id":"c1","markdown":"# Conflicted copy"},
                       {"id":"c2","markdown":"one plus my edit"}]}
            """)])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")
        transport.onRequest = {
            // The clock read (request one) passes untouched; the keystrokes
            // land while the block fetch (request two) is away.
            await MainActor.run {
                if transport.requests.count == 2 { adapter.text = "one plus my edit" }
            }
        }

        await adapter.pullAll()

        XCTAssertEqual(adapter.text, "THEIRS")
        let posted = try transport.jsonBody(of: 2)
        let stashed = try XCTUnwrap(posted["blocks"] as? [[String: String]])
        XCTAssertEqual(stashed.last?["markdown"], "one plus my edit",
                       "the stash carries the fresh text, not the pre-fetch snapshot")
        XCTAssertFalse(adapter.sidecar(for: id).entries.last?.isWritable ?? true)
    }

    func testSecondPullLeavesTheStashInCraft() async throws {
        // The echo: the round after a conflict must converge, not join the
        // stash back into the pad.
        let name = "ccp.pull.echo.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let fetch = blocks("""
            {"items":[{"id":"r1","markdown":"theirs"},
                       {"id":"c1","markdown":"# Conflicted copy — 2026-09-06 19:00 UTC"},
                       {"id":"c2","markdown":"mine edited"}]}
            """)
        let transport = ScriptedTransport([connection, blocks("""
            {"items":[{"id":"r1","markdown":"theirs"}]}
            """), blocks("""
            {"items":[{"id":"c1","markdown":"# Conflicted copy — 2026-09-06 19:00 UTC"},
                       {"id":"c2","markdown":"mine edited"}]}
            """), connection, fetch])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "mine", seeded: ["mine"])
        adapter.storeSidecar(BlockSidecar(entries: [
            BlockSidecarEntry(id: "r1", fingerprint: BlockSidecar.fingerprint("mine")),
        ]), for: id)
        adapter.text = "mine edited"

        await adapter.pullAll()
        XCTAssertEqual(adapter.text, "theirs")
        XCTAssertEqual(transport.requests.count, 3)

        await adapter.pullAll()
        XCTAssertEqual(adapter.text, "theirs", "the stash stays in Craft, out of the pad")
        XCTAssertEqual(adapter.sidecar(for: id).entries.map(\.id), ["r1", "c1", "c2"])
        XCTAssertEqual(adapter.sidecar(for: id).entries.filter { !$0.isWritable }.count, 2)
        XCTAssertEqual(transport.requests.count, 5, "clock plus fetch, no writes")
    }

    func testConvergedClearsDirtyWithoutTouchingText() async throws {
        let name = "ccp.pull.converged.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, blocks("""
            {"items":[{"id":"block-0","markdown":"one"}]}
            """)])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "one")
        // Our own push's mtime bump: dirty, but nothing moved.
        adapter.text = "one"

        await adapter.pullAll()

        // Setting identical text still dirties through didSet — the pull
        // sees text==remote and converges rather than stashing.
        XCTAssertEqual(adapter.text, "one")
        XCTAssertFalse(adapter.isPushDirty(id))
        XCTAssertNotNil(adapter.syncedAt(for: id))
    }

    func testKeystrokesDuringTheStashPostAreNotAdoptedOver() async throws {
        // The second race: deciding on fresh text but adopting after the
        // stash POST strands keystrokes typed while the POST is away. The
        // pull leaves everything — the posted stash is their safety copy.
        let name = "ccp.pull.postrace.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, blocks("""
            {"items":[{"id":"r1","markdown":"theirs"}]}
            """), blocks("""
            {"items":[{"id":"c1","markdown":"# Conflicted copy"},
                       {"id":"c2","markdown":"mine edited"}]}
            """)])
        let adapter = adapter(store, transport)
        let id = try await steadyPad(adapter, text: "mine", seeded: ["mine"])
        adapter.storeSidecar(BlockSidecar(entries: [
            BlockSidecarEntry(id: "r1", fingerprint: BlockSidecar.fingerprint("mine")),
        ]), for: id)
        adapter.text = "mine edited"
        transport.onRequest = {
            // The stash POST (request three) is away: keep typing.
            await MainActor.run {
                if transport.requests.count == 3 { adapter.text = "mine edited!" }
            }
        }

        await adapter.pullAll()

        XCTAssertEqual(adapter.text, "mine edited!", "fresh keystrokes stand")
        XCTAssertTrue(adapter.isPushDirty(id), "their dirty bit stands with them")
        XCTAssertEqual(adapter.stashIDs(for: id), ["c1", "c2"],
                       "the posted copy is pinned even though the adopt aborted")
        XCTAssertEqual(adapter.sidecar(for: id).entries.map(\.id), ["r1"],
                       "no adopt, no reseed")
    }

    func testUnmappedPadMakesNoBlockRequests() async throws {        let name = "ccp.pull.unmapped.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection])
        let adapter = adapter(store, transport)

        await adapter.pullAll()

        XCTAssertEqual(transport.requests.count, 1, "the clock read only")
    }
}
