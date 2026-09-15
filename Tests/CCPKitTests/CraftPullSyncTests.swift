// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import Observation
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

    private func adapter(_ store: UserDefaults, _ transport: ScriptedTransport,
                         dir: URL? = nil) -> (NotesAdapter, CraftNoteDestination) {
        let destination = CraftNoteDestination(defaults: store)
        let adapter = NotesAdapter(defaults: store, defaultName: "Note",
                                   notesDirectory: dir ?? freshNotesDirectory(),
                                   destination: destination)
        adapter.craftTransport = transport
        adapter.craftBaseURLOverride = base
        return (adapter, destination)
    }

    /// A mapped pad holding `text`, with the sidecar seeded from `seeded`
    /// and the dirty bit scrubbed via a no-op push — the steady state a pull
    /// finds in production.
    @discardableResult
    private func steadyPad(_ adapter: NotesAdapter, _ destination: CraftNoteDestination, text: String,
                           seeded: [String]? = nil) async throws -> UUID {
        let id = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = text
        destination.storeBase(.fixture(text, blocks: seeded ?? [text]), for: id)
        destination.setCraftDocumentID("doc1", for: id)
        // Steady means title-converged too, or the flush below spends a
        // rename PUT and never comes back clean.
        destination.storeSyncedTitle(adapter.selectedNoteName, for: id)
        await adapter.flushCraftPush()
        XCTAssertFalse(adapter.isPushDirty(id), "steady state starts clean")
        return id
    }

    private func blocks(_ json: String) -> ScriptedTransport.Script {
        ScriptedTransport.Script(statusCode: 200, json: json)
    }

    /// The trash listing every pull reads between the clock and the fetches.
    /// Empty here; tests needing a remote delete name doc ids.
    private func trash(_ ids: String...) -> ScriptedTransport.Script {
        let items = ids.map { "{\"id\":\"\($0)\"}" }.joined(separator: ",")
        return ScriptedTransport.Script(statusCode: 200, json: "{\"items\":[\(items)]}")
    }

    func testCleanPadAdoptsRemoteEditsAndReseeds() async throws {
        let name = "ccp.pull.adopt.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), blocks("""
            {"items":[{"id":"block-0","markdown":"ONE"}]}
            """)])
        let (adapter, destination) = adapter(store, transport)
        let id = try await steadyPad(adapter, destination, text: "one")

        await adapter.pullAll()

        XCTAssertEqual(transport.requests.count, 3, "clock, trash plus one fetch, no writes")
        XCTAssertEqual(adapter.text, "ONE")
        XCTAssertEqual(destination.base(for: id).blocks.map(\.id), ["block-0"])
        XCTAssertEqual(destination.base(for: id).blocks[0].markdown,
                       "ONE")
        XCTAssertNotNil(destination.syncedAt(for: id))
        XCTAssertFalse(adapter.isPushDirty(id), "adopted text must not re-push")
    }

    func testAdoptSnapshotsPrePullTextForHistory() async throws {
        // ccp-o3k: every replacing pull keeps the way back.
        let name = "ccp.pull.history.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), blocks("""
            {"items":[{"id":"block-0","markdown":"ONE"}]}
            """)])
        let (adapter, destination) = adapter(store, transport)
        let id = try await steadyPad(adapter, destination, text: "one")

        await adapter.pullAll()

        let ring = adapter.snapshots(for: id)
        XCTAssertEqual(ring.count, 1)
        XCTAssertEqual(ring[0].reason, .pull)
        XCTAssertEqual(ring[0].markdown, "one")
        let clock = ISO8601DateFormatter().date(from: "2026-09-06T19:00:00Z")
        XCTAssertEqual(ring[0].date, clock, "dated by the server clock, never the Mac's")
    }

    func testAdoptIntoEmptyPadSnapshotsNothing() async throws {
        // Provisioned but never pushed: an empty sidecar adopts, and
        // emptiness is not worth a snapshot.
        let name = "ccp.pull.history-empty.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), blocks("""
            {"items":[{"id":"block-0","markdown":"hi"}]}
            """)])
        let (adapter, destination) = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)
        XCTAssertEqual(adapter.text, "")
        destination.setCraftDocumentID("doc1", for: id)
        destination.storeSyncedTitle(adapter.selectedNoteName, for: id)

        await adapter.pullAll()

        XCTAssertEqual(adapter.text, "hi")
        XCTAssertTrue(adapter.snapshots(for: id).isEmpty)
    }

    func testIdOnlyReseedReplacesNothing() async throws {
        // Same text under a new block id: the sidecar reseeds, but no text
        // was replaced — no snapshot.
        let name = "ccp.pull.history-reseed.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), blocks("""
            {"items":[{"id":"block-9","markdown":"one"}]}
            """)])
        let (adapter, destination) = adapter(store, transport)
        let id = try await steadyPad(adapter, destination, text: "one")

        await adapter.pullAll()

        XCTAssertEqual(adapter.text, "one")
        XCTAssertEqual(destination.base(for: id).blocks.map(\.id), ["block-9"],
                      "the reseed still lands")
        XCTAssertTrue(adapter.snapshots(for: id).isEmpty)
    }

    func testDirtyPadSkipsWhenRemoteDidNotMove() async throws {
        let name = "ccp.pull.skip.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), blocks("""
            {"items":[{"id":"block-0","markdown":"one"}]}
            """)])
        let (adapter, destination) = adapter(store, transport)
        let id = try await steadyPad(adapter, destination, text: "one")
        adapter.text = "one edited"
        XCTAssertTrue(adapter.isPushDirty(id))

        await adapter.pullAll()

        XCTAssertEqual(adapter.text, "one edited", "local edits stand")
        XCTAssertEqual(destination.base(for: id).blocks.map(\.id), ["block-0"])
        XCTAssertTrue(adapter.isPushDirty(id), "the push still owns these edits")
        XCTAssertNil(destination.syncedAt(for: id), "a skip records nothing")
    }

    func testConvergedPullStampsTheServerTime() async throws {
        let name = "ccp.pull.syncedat.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), blocks("""
            {"items":[{"id":"block-0","markdown":"one"}]}
            """)])
        let (adapter, destination) = adapter(store, transport)
        let id = try await steadyPad(adapter, destination, text: "one")

        await adapter.pullAll()

        let serverTime = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-06T19:00:00Z"))
        XCTAssertEqual(destination.syncedAt(for: id), serverTime, "a converge agrees as of the clock it read")
        XCTAssertEqual(adapter.lastSyncedAt(for: id), serverTime)
    }

    func testNilClockPullStampsLocalTime() async throws {
        // The clock payload without a time still verifies the space, and the
        // converge still proves the agreement — so the local clock stands in
        // for the missing server time rather than leaving "Synced, never
        // synced" on screen.
        let name = "ccp.pull.noclock.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let timeless = ScriptedTransport.Script(statusCode: 200, json: """
            {"space":{"name":"Test"}}
            """)
        let transport = ScriptedTransport([timeless, trash(), blocks("""
            {"items":[{"id":"block-0","markdown":"one"}]}
            """)])
        let (adapter, destination) = adapter(store, transport)
        // Seeded by hand: the version baseline below must be exact, and no
        // setup round may spend it.
        let id = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = "one"
        destination.storeBase(.fixture("one"), for: id)
        destination.setCraftDocumentID("doc1", for: id)
        destination.storeSyncedTitle(adapter.selectedNoteName, for: id)
        let version = adapter.syncedAtVersion

        let before = Date()
        await adapter.pullAll()

        XCTAssertTrue(adapter.isSyncVerified, "the space still verifies without a clock")
        let stamped = try XCTUnwrap(adapter.lastSyncedAt(for: id))
        XCTAssertGreaterThanOrEqual(stamped, before)
        XCTAssertLessThanOrEqual(stamped, Date())
        XCTAssertEqual(adapter.syncedAtVersion, version + 1, "the agreement publishes")
    }

    func testAConflictKeepsThePanelAndPreservesCraftsVersion() async throws {
        // Both sides changed the same block. The panel's text is what the
        // user was last looking at, so it stands; Craft's version is kept in
        // the popover and in history rather than written back into the user's
        // Craft document as a copy of their own typing (ccp-c2x5).
        let name = "ccp.pull.conflict.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), blocks("""
            {"items":[{"id":"r1","markdown":"theirs"}]}
            """)])
        let (adapter, destination) = adapter(store, transport)
        let id = try await steadyPad(adapter, destination, text: "mine", seeded: ["mine"])
        destination.storeBase(.fixture("mine", ids: ["r1"]), for: id)
        adapter.text = "mine edited"

        await adapter.pullAll()

        XCTAssertEqual(transport.requests.count, 3, "clock, trash, one fetch — and no writes")
        XCTAssertEqual(adapter.text, "mine edited", "the panel keeps what was typed in it")
        XCTAssertEqual(adapter.conflicts(for: id).map(\.slices), [["theirs"]])
        XCTAssertEqual(adapter.snapshots(for: id).first?.markdown, "theirs",
                       "Craft's version is restorable")
        XCTAssertEqual(adapter.snapshots(for: id).first?.reason, .conflict)
        XCTAssertTrue(adapter.isPushDirty(id), "the merged text still owes Craft a push")
    }

    func testConflictRecordsCapDismissAndDropWithTheNote() async throws {
        let name = "ccp.pull.records.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let adapter = NotesAdapter(defaults: store, defaultName: "Note", notesDirectory: freshNotesDirectory())
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

    func testReadingConflictsRegistersAnObservationDependency() throws {
        let name = "ccp.pull.observe.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let adapter = NotesAdapter(defaults: store, defaultName: "Note",
                                   notesDirectory: freshNotesDirectory())
        let id = try XCTUnwrap(adapter.selectedNoteID)

        // The toolbar reads through conflicts(for:) so a background pull's
        // record wakes it: the read must register the version as a
        // dependency, not merely return the records.
        let fired = expectation(description: "a record wakes the reader")
        withObservationTracking {
            _ = adapter.conflicts(for: id)
        } onChange: {
            fired.fulfill()
        }
        adapter.recordConflict(slices: ["kept"], date: nil, for: id)
        wait(for: [fired], timeout: 1)
    }

    func testCloseNoteDropsAllSyncState() async throws {
        let name = "ccp.pull.close.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), blocks("""
            {"items":[{"id":"r1","markdown":"theirs"}]}
            """)])
        let (adapter, destination) = adapter(store, transport)
        let id = try await steadyPad(adapter, destination, text: "mine", seeded: ["mine"])
        destination.storeBase(.fixture("mine", ids: ["r1"]), for: id)
        adapter.text = "mine edited"

        await adapter.pullAll()
        XCTAssertFalse(adapter.conflicts(for: id).isEmpty, "a conflict to drop")
        XCTAssertFalse(destination.base(for: id).isEmpty)

        adapter.createNote()
        XCTAssertTrue(adapter.deleteNote(id))

        XCTAssertEqual(adapter.conflicts(for: id), [])
        XCTAssertEqual(destination.stashIDs(for: id), [])
        XCTAssertNil(destination.syncedAt(for: id))
        XCTAssertEqual(destination.base(for: id).blocks, [])
        XCTAssertNil(destination.craftDocumentID(for: id))
        XCTAssertNil(destination.syncedTitle(for: id), "title baselines leave with the note")
        XCTAssertNil(destination.titleRenameDate(for: id))
    }

    func testFailedFetchLeavesPadSidecarAndDirtyBitAlone() async throws {
        let name = "ccp.pull.failure.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(),
                                           ScriptedTransport.Script(statusCode: 500, json: "{}")])
        let (adapter, destination) = adapter(store, transport)
        let id = try await steadyPad(adapter, destination, text: "one")
        adapter.text = "one edited"

        await adapter.pullAll()

        XCTAssertEqual(adapter.text, "one edited")
        XCTAssertEqual(destination.base(for: id).blocks.map(\.id), ["block-0"])
        XCTAssertTrue(adapter.isPushDirty(id), "a failed read must not clear unpushed edits")
        XCTAssertNil(destination.syncedAt(for: id))
    }

    func testHandMappedPadKeepsBothSidesAndStartsRemembering() async throws {
        // A pad mapped onto a Craft document that already held text, with no
        // agreement on record. Adopting would wipe local text Craft never
        // confirmed; pushing would wipe Craft's. Record what each side holds
        // and let the next real edit decide.
        let name = "ccp.pull.handmapped.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), blocks("""
            {"items":[{"id":"r1","markdown":"theirs"}]}
            """)])
        let (adapter, destination) = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = "my notes"
        destination.setCraftDocumentID("doc1", for: id)
        destination.storeSyncedTitle(adapter.selectedNoteName, for: id)

        await adapter.pullAll()

        XCTAssertEqual(transport.requests.count, 3, "clock, trash, fetch — and no writes")
        XCTAssertEqual(adapter.text, "my notes", "unconfirmed local text is never wiped")
        XCTAssertEqual(destination.base(for: id).localText, "my notes")
        XCTAssertEqual(destination.base(for: id).blocks.map(\.markdown), ["theirs"])
        XCTAssertTrue(adapter.conflicts(for: id).isEmpty, "nothing was lost, so nothing to report")
    }

    func testKeystrokesDuringTheFetchAreNotLost() async throws {
        // The race: deciding on pre-fetch text would strand keystrokes typed
        // while the fetch was away — in neither the pad nor Craft.
        let name = "ccp.pull.race.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), blocks("""
            {"items":[{"id":"block-0","markdown":"THEIRS"}]}
            """)])
        let (adapter, destination) = adapter(store, transport)
        let id = try await steadyPad(adapter, destination, text: "one")
        transport.onRequest = {
            // The clock read (request one) passes untouched; the keystrokes
            // land while the block fetch (request two) is away.
            await MainActor.run {
                if transport.requests.count == 3 { adapter.text = "one plus my edit" }
            }
        }

        await adapter.pullAll()

        XCTAssertEqual(adapter.text, "one plus my edit",
                       "keystrokes newer than the fetch win the block they touched")
        XCTAssertEqual(adapter.conflicts(for: id).map(\.slices), [["THEIRS"]],
                       "and Craft's version is reported, not silently dropped")
    }

    func testConvergedClearsDirtyWithoutTouchingText() async throws {
        let name = "ccp.pull.converged.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash(), blocks("""
            {"items":[{"id":"block-0","markdown":"one"}]}
            """)])
        let (adapter, destination) = adapter(store, transport)
        let id = try await steadyPad(adapter, destination, text: "one")
        // Our own push's mtime bump: dirty, but nothing moved.
        adapter.text = "one"

        await adapter.pullAll()

        // Setting identical text still dirties through didSet — the pull
        // sees text==remote and converges rather than stashing.
        XCTAssertEqual(adapter.text, "one")
        XCTAssertFalse(adapter.isPushDirty(id))
        XCTAssertNotNil(destination.syncedAt(for: id))
    }

    func testUnmappedPadMakesNoBlockRequests() async throws {        let name = "ccp.pull.unmapped.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash()])
        let (adapter, destination) = adapter(store, transport)

        await adapter.pullAll()

        XCTAssertEqual(transport.requests.count, 2, "the clock read plus the trash listing")
    }

    // MARK: - Push/pull serialization

    /// One round at a time: a debounced push landing inside a pull would
    /// diff against a sidecar the pull is about to replace, and a pull
    /// fetching under a push reads the half-written remote as a move and
    /// stashes our own writes. The latch holds one side mid-flight while
    /// the other side arrives; request counts prove they never overlap.
    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func release() {
            lock.lock()
            released = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    func testPushWaitsForAnInFlightPull() async throws {
        let name = "ccp.sync.pushwaits.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let fetch = Latch()
        let transport = ScriptedTransport([connection, trash(), blocks("""
            {"items":[{"id":"block-0","markdown":"one"}]}
            """)])
        transport.onRequest = {
            if transport.requests.count == 3 { await fetch.wait() }
        }
        let (adapter, destination) = adapter(store, transport)
        let id = try await steadyPad(adapter, destination, text: "one")
        adapter.text = "one edited"

        async let pull: () = adapter.pullAll()
        let pullReachedFetch = await becomesTrue { transport.requests.count == 3 }
        XCTAssertTrue(pullReachedFetch, "the pull reached its fetch")

        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 3, "the push does not write beside the pull")
        fetch.release()
        await pull
        XCTAssertEqual(transport.requests.count, 3, "an unmoved remote with local edits skips clean")

        transport.scripts += [trash(), blocks("""
            {"items":[{"id":"block-0","markdown":"one edited"}]}
            """)]
        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 6,
                       "trash sweep plus the deferred PUT and its read-back")
        let body = try transport.jsonBody(of: 4)
        XCTAssertEqual(body["blocks"] as? [[String: String]],
                       [["id": "block-0", "markdown": "one edited"]])
        XCTAssertFalse(adapter.isPushDirty(id))
    }

    func testPullYieldsToAnInFlightPush() async throws {
        let name = "ccp.sync.pullyields.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let put = Latch()
        let transport = ScriptedTransport([trash(), blocks("""
            {"items":[{"id":"block-0","markdown":"one edited"}]}
            """), blocks("""
            {"items":[{"id":"block-0","markdown":"one edited"}]}
            """)])
        transport.onRequest = {
            if transport.requests.count == 2 { await put.wait() }
        }
        let (adapter, destination) = adapter(store, transport)
        let id = try await steadyPad(adapter, destination, text: "one")
        adapter.text = "one edited"

        async let push: () = adapter.flushCraftPush()
        let pushReachedPut = await becomesTrue { transport.requests.count == 2 }
        XCTAssertTrue(pushReachedPut, "the push reached its PUT")

        await adapter.pullAll()

        XCTAssertEqual(transport.requests.count, 2, "the pull does not fetch under the push")
        put.release()
        await push
        await Task.yield()
        let noUnwatchedPull = await becomesTrue { transport.requests.count > 3 }
        XCTAssertFalse(noUnwatchedPull, "no pull starts unwatched while the panel is shut")

        transport.scripts += [connection, trash(), blocks("""
            {"items":[{"id":"block-0","markdown":"one edited"}]}
            """)]
        await adapter.pullAll()

        XCTAssertEqual(transport.requests.count, 6,
                       "clock, trash plus fetch once the push and its read-back have landed")
        XCTAssertEqual(adapter.text, "one edited")
        XCTAssertFalse(adapter.isPushDirty(id), "the converged pull stands cleared")
    }

    func testSecondPullCoalescesOntoAnInFlightPull() async throws {
        // Two pulls deciding on one pre-store sidecar double-post the stash:
        // the second yields and re-runs after the first lands instead.
        let name = "ccp.sync.pullcoalesce.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let fetch = Latch()
        let same = blocks("""
            {"items":[{"id":"block-0","markdown":"one"}]}
            """)
        let transport = ScriptedTransport([connection, trash(), same])
        transport.onRequest = {
            if transport.requests.count == 6 { await fetch.wait() }
        }
        let (adapter, destination) = adapter(store, transport)
        _ = try await steadyPad(adapter, destination, text: "one")

        adapter.activate()
        let verified = await becomesTrue { adapter.isSyncVerified }
        XCTAssertTrue(verified, "the activate pull lands first")
        XCTAssertEqual(transport.requests.count, 3)

        transport.scripts += [connection, trash(), same, connection, trash(), same]
        async let first: () = adapter.pullAll()
        let firstReachedFetch = await becomesTrue { transport.requests.count == 6 }
        XCTAssertTrue(firstReachedFetch, "the first pull reached its fetch")

        await adapter.pullAll()

        XCTAssertEqual(transport.requests.count, 6, "the second pull does not fetch beside the first")
        fetch.release()
        await first
        let rerunLanded = await becomesTrue { adapter.isSyncVerified && transport.requests.count == 9 }
        XCTAssertTrue(rerunLanded, "the coalesced pull re-runs once the first lands")
        XCTAssertTrue(adapter.isSyncVerified)
    }
}
