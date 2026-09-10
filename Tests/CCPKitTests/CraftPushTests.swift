// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

/// Scripted network: one canned response per request, every request captured
/// for body assertions. An optional hook runs inside `data(for:)` — the
/// mid-flight-typing test uses it to change the pad while a push is away.
final class ScriptedTransport: CraftTransport, @unchecked Sendable {
    struct Script {
        var statusCode: Int
        var json: String
        var headers: [String: String] = [:]
    }

    var scripts: [Script]
    /// What `GET /blocks` answers, when set: the document as (id, markdown)
    /// pairs. Every push reads the document back to record the new agreement
    /// (ccp-c2x5), and scripting that read into each test would say nothing
    /// about the test. Unset, a GET spends a script like any other request.
    var documentBlocks: [(id: String, markdown: String)]?
    private(set) var requests: [URLRequest] = []
    var onRequest: (() async -> Void)?
    /// Dynamic echo: answers from the request itself. Takes precedence over
    /// the script queue — the multi-pad test needs per-request ids in an
    /// order the dirty set does not promise.
    var respond: ((URLRequest) -> Script)?

    init(_ scripts: [Script]) {
        self.scripts = scripts
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        await onRequest?()
        if let documentBlocks, request.httpMethod == "GET",
           request.url?.lastPathComponent == "blocks" {
            let items = documentBlocks.map {
                "{\"id\":\"\($0.id)\",\"markdown\":\"\($0.markdown)\"}"
            }.joined(separator: ",")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (Data("{\"items\":[\(items)]}".utf8), response)
        }
        if let respond {
            let next = respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: next.statusCode,
                                           httpVersion: nil, headerFields: next.headers)!
            return (Data(next.json.utf8), response)
        }
        guard !scripts.isEmpty else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 500,
                                           httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), response)
        }
        let next = scripts.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.statusCode,
                                       httpVersion: nil, headerFields: next.headers)!
        return (Data(next.json.utf8), response)
    }

    func jsonBody(of index: Int) throws -> [String: Any] {
        let data = try XCTUnwrap(requests[index].httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// The wire half of the push: methods, paths, batched bodies, echo parsing,
/// and the failure mapping. Echoes arrive in the documented `items` envelope;
/// the older `blocks` envelope and bare arrays still parse as tolerance.
final class CraftPushWireTests: XCTestCase {
    private let base = URL(string: "https://connect.craft.do/links/test/api/v1")!

    private func client(_ transport: ScriptedTransport) -> CraftClient {
        CraftClient(baseURL: base, transport: transport)
    }

    func testPutSendsBatchedUpdatesAndReadsTheEnvelopeEcho() async throws {
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"items":[{"id":"b1","markdown":"TWO!","type":"text"}]}
            """)])
        let echo = try await client(transport).updateBlocks(
            [BlockUpdate(id: "b1", markdown: "TWO")])

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].httpMethod, "PUT")
        XCTAssertEqual(transport.requests[0].url?.lastPathComponent, "blocks")
        let body = try transport.jsonBody(of: 0)
        let blocks = try XCTUnwrap(body["blocks"] as? [[String: String]])
        XCTAssertEqual(blocks, [["id": "b1", "markdown": "TWO"]])
        XCTAssertEqual(echo, [CraftBlock(id: "b1", markdown: "TWO!")])
    }

    func testEchoParsesAsABareArrayToo() async throws {
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            [{"id":"b1","markdown":"TWO!"}]
            """)])
        let echo = try await client(transport).updateBlocks(
            [BlockUpdate(id: "b1", markdown: "TWO")])
        XCTAssertEqual(echo, [CraftBlock(id: "b1", markdown: "TWO!")])
    }

    func testEchoParsesTheLegacyBlocksEnvelopeToo() async throws {
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"blocks":[{"id":"b1","markdown":"TWO!"}]}
            """)])
        let echo = try await client(transport).updateBlocks(
            [BlockUpdate(id: "b1", markdown: "TWO")])
        XCTAssertEqual(echo, [CraftBlock(id: "b1", markdown: "TWO!")])
    }

    func testPostWithoutAnchorGoesToStartOfDocument() async throws {
        // Empty-document first sync: no head block to address.
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"items":[{"id":"n1","markdown":"one"}]}
            """)])
        _ = try await client(transport).postBlocks(
            [BlockInsert(afterID: nil, markdown: "one")], documentID: "doc1")

        let body = try transport.jsonBody(of: 0)
        let position = try XCTUnwrap(body["position"] as? [String: String])
        XCTAssertEqual(position["position"], "start")
        XCTAssertEqual(position["pageId"], "doc1")
        let blocks = try XCTUnwrap(body["blocks"] as? [[String: String]])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0]["type"], "text")
        XCTAssertEqual(blocks[0]["markdown"], "one")
    }

    func testPostWithHeadSiblingPostsAtEndThenMovesBeforeIt() async throws {
        // Head of a non-empty document: neither "start"+pageId nor
        // "before"+siblingId inserts above the first block — both merge into
        // it (observed live 2026-09-05) — so the batch lands at the end and
        // is moved before the head (ccp-gfe5).
        let transport = ScriptedTransport([
            .init(statusCode: 200, json: """
                {"items":[{"id":"n1","markdown":"new"}]}
                """),
            .init(statusCode: 200, json: """
                {"items":[{"id":"n1"}]}
                """),
        ])
        let echo = try await client(transport).postBlocks(
            [BlockInsert(afterID: nil, markdown: "new")], documentID: "doc1",
            headSiblingID: "b0")

        XCTAssertEqual(echo, [CraftBlock(id: "n1", markdown: "new")])
        XCTAssertEqual(transport.requests.count, 2)
        let postBody = try transport.jsonBody(of: 0)
        let postPosition = try XCTUnwrap(postBody["position"] as? [String: String])
        XCTAssertEqual(postPosition["position"], "end")
        XCTAssertEqual(postPosition["pageId"], "doc1")
        XCTAssertEqual(transport.requests[1].httpMethod, "PUT")
        XCTAssertEqual(transport.requests[1].url?.absoluteString.hasSuffix("blocks/move"), true)
        let moveBody = try transport.jsonBody(of: 1)
        XCTAssertEqual(moveBody["blockIds"] as? [String], ["n1"])
        let movePosition = try XCTUnwrap(moveBody["position"] as? [String: String])
        XCTAssertEqual(movePosition["position"], "before")
        XCTAssertEqual(movePosition["siblingId"], "b0")
    }

    func testHeadMoveFailureRollsBackThePost() async throws {
        // POST ok, MOVE 500s: the posted block is deleted so a retry
        // re-posts rather than orphaning a copy at the end.
        let transport = ScriptedTransport([
            .init(statusCode: 200, json: """
                {"items":[{"id":"n1","markdown":"new"}]}
                """),
            .init(statusCode: 500, json: "{}"),
            .init(statusCode: 200, json: "{}"),
        ])
        do {
            _ = try await client(transport).postBlocks(
                [BlockInsert(afterID: nil, markdown: "new")], documentID: "doc1",
                headSiblingID: "b0")
            XCTFail("a failed move must throw — the head insert did not land")
        } catch let error as CraftClientError {
            XCTAssertEqual(error, .unreachable(statusCode: 500))
        } catch {
            XCTFail("wrong error: \(error)")
        }

        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(transport.requests[2].httpMethod, "DELETE")
        let deleteBody = try transport.jsonBody(of: 2)
        XCTAssertEqual(deleteBody["blockIds"] as? [String], ["n1"])
    }

    func testHeadMoveEchoMustNameBackEveryPostedID() async throws {
        // POST ok, MOVE 200s but echoes no ids: the blocks sit at the end
        // while the sidecar would claim the head — roll back like a failure.
        let transport = ScriptedTransport([
            .init(statusCode: 200, json: """
                {"items":[{"id":"n1","markdown":"x"},{"id":"n2","markdown":"y"}]}
                """),
            .init(statusCode: 200, json: """
                {"items":[]}
                """),
            .init(statusCode: 200, json: "{}"),
        ])
        do {
            _ = try await client(transport).postBlocks(
                [BlockInsert(afterID: nil, markdown: "x"),
                 BlockInsert(afterID: nil, markdown: "y")], documentID: "doc1",
                headSiblingID: "b0")
            XCTFail("a short move echo cannot be attributed — fail, don't record")
        } catch let error as CraftClientError {
            XCTAssertEqual(error, .unreachable(statusCode: nil))
        } catch {
            XCTFail("wrong error: \(error)")
        }

        XCTAssertEqual(transport.requests.count, 3, "POST, MOVE, rollback DELETE")
        let deleteBody = try transport.jsonBody(of: 2)
        XCTAssertEqual(Set(deleteBody["blockIds"] as? [String] ?? []), ["n1", "n2"])
    }

    func testHeadMoveEchoToleratesOtherEnvelopes() async throws {
        // The move echo carries ids only, in whatever envelope arrives.
        for json in ["{\"blocks\":[{\"id\":\"n1\"}]}", "[{\"id\":\"n1\"}]"] {
            let transport = ScriptedTransport([
                .init(statusCode: 200, json: """
                    {"items":[{"id":"n1","markdown":"new"}]}
                    """),
                .init(statusCode: 200, json: json),
            ])
            let echo = try await client(transport).postBlocks(
                [BlockInsert(afterID: nil, markdown: "new")], documentID: "doc1",
                headSiblingID: "b0")
            XCTAssertEqual(echo.map(\.id), ["n1"], "envelope: \(json)")
            XCTAssertEqual(transport.requests.count, 2, "no rollback on \(json)")
        }
    }

    func testHeadMoveRateLimitSkipsTheRollback() async throws {
        // POST ok, MOVE 429s: another write into a throttled window only
        // spends budget, so the limit rethrows bare and the limit's own
        // retry re-posts.
        let transport = ScriptedTransport([
            .init(statusCode: 200, json: """
                {"items":[{"id":"n1","markdown":"new"}]}
                """),
            .init(statusCode: 429, json: "{}", headers: ["Retry-After": "9"]),
        ])
        do {
            _ = try await client(transport).postBlocks(
                [BlockInsert(afterID: nil, markdown: "new")], documentID: "doc1",
                headSiblingID: "b0")
            XCTFail("a limited move must throw")
        } catch let error as CraftClientError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 9))
        } catch {
            XCTFail("wrong error: \(error)")
        }

        XCTAssertEqual(transport.requests.count, 2, "no DELETE into the throttled window")
    }

    func testPostWithAnchorFollowsTheSibling() async throws {
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"items":[{"id":"n1","markdown":"new"}]}
            """)])
        _ = try await client(transport).postBlocks(
            [BlockInsert(afterID: "b0", markdown: "new")], documentID: "doc1")

        let body = try transport.jsonBody(of: 0)
        let position = try XCTUnwrap(body["position"] as? [String: String])
        XCTAssertEqual(position["position"], "after")
        XCTAssertEqual(position["siblingId"], "b0")
    }

    func testSharedAnchorBatchPostsOnce() async throws {
        let transport = ScriptedTransport([
            .init(statusCode: 200, json: "{\"blocks\":[{\"id\":\"n1\",\"markdown\":\"x\"},{\"id\":\"n2\",\"markdown\":\"y\"}]}"),
        ])
        let echo = try await client(transport).postBlocks(
            [BlockInsert(afterID: "b0", markdown: "x"),
             BlockInsert(afterID: "b0", markdown: "y")], documentID: "doc1")

        XCTAssertEqual(transport.requests.count, 1, "one shared anchor rides one batch")
        XCTAssertEqual(echo.map(\.id), ["n1", "n2"])
    }

    func testDeleteSendsBlockIds() async throws {
        let transport = ScriptedTransport([.init(statusCode: 200, json: "{}")])
        try await client(transport).deleteBlocks(["b0", "b2"])

        XCTAssertEqual(transport.requests[0].httpMethod, "DELETE")
        let body = try transport.jsonBody(of: 0)
        XCTAssertEqual(body["blockIds"] as? [String], ["b0", "b2"])
    }

    func testRateLimitCarriesRetryAfter() async throws {
        let transport = ScriptedTransport(
            [.init(statusCode: 429, json: "{}", headers: ["Retry-After": "7"])])
        do {
            _ = try await client(transport).updateBlocks(
                [BlockUpdate(id: "b1", markdown: "x")])
            XCTFail("a 429 must throw")
        } catch let error as CraftClientError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 7))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testServerErrorIsUnreachableWithItsStatus() async throws {
        let transport = ScriptedTransport([.init(statusCode: 500, json: "{}")])
        do {
            _ = try await client(transport).updateBlocks(
                [BlockUpdate(id: "b1", markdown: "x")])
            XCTFail("a 500 must throw")
        } catch let error as CraftClientError {
            XCTAssertEqual(error, .unreachable(statusCode: 500))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testShortEchoFailsTheGroup() async throws {
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"items":[{"id":"n1","markdown":"x"}]}
            """)])
        do {
            _ = try await client(transport).postBlocks(
                [BlockInsert(afterID: "b0", markdown: "x"),
                 BlockInsert(afterID: "b0", markdown: "y")], documentID: "doc1")
            XCTFail("a short echo cannot be attributed — fail, don't guess")
        } catch let error as CraftClientError {
            XCTAssertEqual(error, .unreachable(statusCode: nil))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

/// The push plan: what changed in the pad since the base, named with the
/// Craft ids the base holds. Both sequences are our markdown, which is what
/// makes the diff exact — the predecessor compared our slices against hashes
/// of Craft's respelled form and could never come back equal (ccp-c2x5).
final class BlockPushPlanTests: XCTestCase {
    private func base(_ markdowns: [String], local: String? = nil,
                      writable: Bool = true) -> PadSyncBase {
        PadSyncBase(localText: local ?? CraftPull.join(markdowns),
                    blocks: markdowns.enumerated().map { index, markdown in
                        BaseBlock(id: "block-\(index)", markdown: markdown,
                                  isWritable: writable)
                    })
    }

    private func plan(_ base: PadSyncBase, _ text: String) -> BlockPushPlan {
        BlockPushPlan.plan(from: base, to: CraftBlockSplitter.slices(in: text).map(\.markdown))
    }

    func testUnchangedTextPlansNothing() {
        XCTAssertTrue(plan(base(["one", "two"]), "one  \ntwo").isEmpty)
    }

    func testARespelledBlockIsNotAChange() {
        // The bug: Craft holds "*italic*" for a block the pad spells
        // "_italic_", and that must never plan a write.
        let recorded = PadSyncBase(localText: "an _italic_ word",
                                   blocks: [BaseBlock(id: "b", markdown: "an *italic* word")])
        XCTAssertTrue(plan(recorded, "an _italic_ word").isEmpty)
    }

    func testEditedBlockUpdatesInPlace() {
        let result = plan(base(["one", "two"]), "one  \nTWO")
        XCTAssertEqual(result.updates, [BlockUpdate(id: "block-1", markdown: "TWO")])
        XCTAssertTrue(result.inserts.isEmpty)
        XCTAssertTrue(result.deletes.isEmpty)
    }

    func testAppendedBlockAnchorsAfterTheLastOne() {
        let result = plan(base(["one"]), "one  \ntwo")
        XCTAssertEqual(result.inserts, [BlockInsert(afterID: "block-0", markdown: "two")])
        XCTAssertTrue(result.updates.isEmpty)
    }

    func testBlockInsertedAtTheHeadHasNoAnchor() {
        let result = plan(base(["one"]), "zero  \none")
        XCTAssertEqual(result.inserts, [BlockInsert(afterID: nil, markdown: "zero")])
    }

    func testInsertAfterAnEditedBlockAnchorsToTheEdit() {
        // The edited block keeps its id, so it is still the addressable
        // predecessor.
        let result = plan(base(["one", "two"]), "ONE  \nnew  \ntwo")
        XCTAssertEqual(result.updates, [BlockUpdate(id: "block-0", markdown: "ONE")])
        XCTAssertEqual(result.inserts, [BlockInsert(afterID: "block-0", markdown: "new")])
    }

    func testRemovedBlockDeletes() {
        let result = plan(base(["one", "two"]), "one")
        XCTAssertEqual(result.deletes, ["block-1"])
        XCTAssertTrue(result.updates.isEmpty)
    }

    func testInsertAfterADeletedBlockAnchorsPastIt() {
        let result = plan(base(["one", "two", "three"]), "one  \nthree  \nfour")
        XCTAssertEqual(result.deletes, ["block-1"])
        XCTAssertEqual(result.inserts, [BlockInsert(afterID: "block-2", markdown: "four")])
    }

    func testABlockSplitInTwoKeepsItsIdOnTheFirstPiece() {
        let result = plan(base(["one two"]), "one  \ntwo")
        XCTAssertEqual(result.updates, [BlockUpdate(id: "block-0", markdown: "one")])
        XCTAssertEqual(result.inserts, [BlockInsert(afterID: "block-0", markdown: "two")])
    }

    func testPinnedBlocksAreNeverWritten() {
        // Craft will not take these back, so an edit to one in the pad is
        // dropped rather than flattening what Craft owns.
        let result = plan(base(["one", "two"], writable: false), "ONE  \nTWO")
        XCTAssertTrue(result.isEmpty, "nothing pinned may be updated or deleted")
    }

    func testClearingThePadDeletesEveryWritableBlock() {
        XCTAssertEqual(plan(base(["one", "two"]), "").deletes, ["block-0", "block-1"])
    }

    func testAMisalignedBaseRepostsInsteadOfGuessing() {
        // Craft split a block, so slice index no longer names a block id.
        // Reposting churns; mispairing would put one block's text under
        // another block's id.
        let misaligned = PadSyncBase(
            localText: "one two",
            blocks: [BaseBlock(id: "a", markdown: "one"), BaseBlock(id: "b", markdown: "two")])
        let result = plan(misaligned, "one two edited")
        XCTAssertEqual(result.deletes, ["a", "b"])
        XCTAssertEqual(result.inserts.map(\.markdown), ["one two edited"])
        XCTAssertTrue(result.updates.isEmpty, "no id is gambled on a guess")
    }

    func testAMisalignedRepostLeavesPinnedBlocksAlone() {
        let misaligned = PadSyncBase(
            localText: "one two",
            blocks: [BaseBlock(id: "a", markdown: "one"),
                     BaseBlock(id: "keep", markdown: "<collection>x</collection>",
                               isWritable: false)])
        let result = plan(misaligned, "edited")
        XCTAssertEqual(result.deletes, ["a"])
        XCTAssertEqual(result.inserts, [BlockInsert(afterID: "keep", markdown: "edited")])
    }
}

/// The two JSON-dict stores behind one helper: unreadable reads as empty
/// without touching the bytes, and removing the last entry removes the key.
final class DefaultsMapTests: XCTestCase {
    func testRoundTripAndRemoveOnEmpty() throws {
        let name = "ccp.defaultsmap.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        store.removePersistentDomain(forName: name)
        defer { store.removePersistentDomain(forName: name) }
        let map = DefaultsMap<PadSyncBase>(defaults: store, key: "test.map")

        XCTAssertTrue(map.load().isEmpty)
        let base = PadSyncBase.fixture("one", ids: ["b1"])
        map.set(base, for: "pad")
        XCTAssertEqual(map.load()["pad"], base)
        map.set(nil, for: "pad")
        XCTAssertTrue(map.load().isEmpty)
        XCTAssertNil(store.object(forKey: "test.map"), "no lingering empty dictionary")
    }

    func testGarbageReadsEmptyAndSurvives() throws {
        let name = "ccp.defaultsmap.garbage.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        store.removePersistentDomain(forName: name)
        defer { store.removePersistentDomain(forName: name) }
        let garbage = Data("{\"not\":\"a map\"}".utf8)
        store.set(garbage, forKey: "test.map")

        let map = DefaultsMap<PadSyncBase>(defaults: store, key: "test.map")
        XCTAssertTrue(map.load().isEmpty)
        XCTAssertTrue(map.hasUndecodableBytes)
        XCTAssertEqual(store.data(forKey: "test.map"), garbage)
    }

    func testStoredEmptyMapIsNotCorruption() throws {
        let name = "ccp.defaultsmap.empty.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        store.removePersistentDomain(forName: name)
        defer { store.removePersistentDomain(forName: name) }
        // What older builds wrote when the last entry dropped.
        store.set(Data("{}".utf8), forKey: "test.map")

        let map = DefaultsMap<PadSyncBase>(defaults: store, key: "test.map")
        XCTAssertTrue(map.load().isEmpty)
        XCTAssertFalse(map.hasUndecodableBytes, "valid empty JSON must not arm the rescue")
    }
}

/// The adapter half: flush spends the plan end to end and records what Craft
/// holds afterwards as the new agreement.
@MainActor
final class CraftPushAdapterTests: XCTestCase {
    private let base = URL(string: "https://connect.craft.do/links/test/api/v1")!

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

    private func seed(_ adapter: NotesAdapter, _ destination: CraftNoteDestination,
                      text: String) throws -> UUID {
        let id = try XCTUnwrap(adapter.selectedNoteID)
        destination.storeBase(.fixture(text), for: id)
        destination.setCraftDocumentID("doc1", for: id)
        // Seeded means converged, title included — or every flush below
        // spends a rename PUT first and the counts shift.
        destination.storeSyncedTitle(adapter.selectedNoteName, for: id)
        return id
    }

    /// Empty trash listing, spent by the pre-write sweep (ccp-5fom) in every
    /// round that pushes mapped pads.
    private func emptyTrash() -> ScriptedTransport.Script {
        .init(statusCode: 200, json: "{\"items\":[]}")
    }

    func testFlushPutsTheEditAndStoresTheEcho() async throws {
        let name = "ccp.push.flush.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([emptyTrash(), .init(statusCode: 200, json: """
            {"items":[{"id":"block-1","markdown":"TWO!"}]}
            """)])
        transport.documentBlocks = [("block-0", "one"), ("block-1", "TWO!")]
        let (adapter, destination) = adapter(store, transport)
        let id = try seed(adapter, destination, text: "one\n\ntwo\n")

        adapter.text = "one\n\nTWO\n"
        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 3,
                       "trash sweep, one PUT, and the read-back that records the agreement")
        XCTAssertEqual(destination.base(for: id).blocks[1].markdown,
                       "TWO!")
        XCTAssertEqual(adapter.text, "one\n\nTWO\n",
                       "a push never rewrites the pad — the user's spelling stands")
    }

    func testSuccessfulPushStampsLastSyncedAt() async throws {
        // The toolbar's history popover reads this: a pushed-clean pad
        // agrees with Craft as of now, not as of the last pull.
        let name = "ccp.push.syncedat.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([emptyTrash(), .init(statusCode: 200, json: """
            {"items":[{"id":"block-1","markdown":"TWO!"}]}
            """)])
        let (adapter, destination) = adapter(store, transport)
        let id = try seed(adapter, destination, text: "one\n\ntwo\n")
        XCTAssertNil(adapter.lastSyncedAt(for: id), "never agreed before the first round")

        let before = Date()
        adapter.text = "one\n\nTWO\n"
        await adapter.flushCraftPush()

        XCTAssertFalse(adapter.isPushDirty(id))
        let stamped = try XCTUnwrap(adapter.lastSyncedAt(for: id))
        XCTAssertGreaterThanOrEqual(stamped, before)
        XCTAssertLessThanOrEqual(stamped, Date())
    }

    func testFailedPushLeavesLastSyncedAtUntouched() async throws {
        let name = "ccp.push.syncedatfail.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([.init(statusCode: 500, json: "{}")])
        let (adapter, _) = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)

        adapter.text = "one\n\nTWO\n"
        await adapter.flushCraftPush()

        XCTAssertTrue(adapter.isPushDirty(id))
        XCTAssertNil(adapter.lastSyncedAt(for: id), "a failed round agrees on nothing")
    }

    func testMidFlightTypingStaysDirtyForAnotherRound() async throws {
        let name = "ccp.push.midflight.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([
            emptyTrash(),
            .init(statusCode: 200, json: """
                {"items":[{"id":"block-1","markdown":"TWO!"}]}
                """),
            .init(statusCode: 200, json: """
                {"items":[{"id":"block-0","markdown":"one"},{"id":"block-1","markdown":"TWO!"}]}
                """),
            emptyTrash(),
            .init(statusCode: 200, json: """
                {"items":[{"id":"block-1","markdown":"TW0!"}]}
                """),
            .init(statusCode: 200, json: """
                {"items":[{"id":"block-0","markdown":"one"},{"id":"block-1","markdown":"TW0!"}]}
                """),
        ])
        let (adapter, destination) = adapter(store, transport)
        let id = try seed(adapter, destination, text: "one\n\ntwo\n")

        adapter.text = "one\n\nTWO\n"
        transport.onRequest = {
            // The user retyped the pushed block while the PUT was away.
            await MainActor.run {
                if transport.requests.last?.httpMethod == "PUT" {
                    adapter.text = "one\n\nTW0\n"
                }
            }
        }
        await adapter.flushCraftPush()

        XCTAssertEqual(adapter.text, "one\n\nTW0\n", "the pad is never rewritten by a push")
        XCTAssertTrue(adapter.isPushDirty(id),
                      "the base describes the pushed text, not the current text")

        await adapter.flushCraftPush()
        XCTAssertFalse(adapter.isPushDirty(id))
        XCTAssertEqual(destination.base(for: id).blocks[1].markdown,
                       "TW0!")
        XCTAssertEqual(adapter.text, "one\n\nTW0\n")
    }

    func testFailureLeavesTheSidecarUntouched() async throws {
        let name = "ccp.push.failure.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([.init(statusCode: 500, json: "{}")])
        let (adapter, destination) = adapter(store, transport)
        let id = try seed(adapter, destination, text: "one\n\ntwo\n")
        let before = destination.base(for: id)

        adapter.text = "one\n\nTWO\n"
        await adapter.flushCraftPush()

        XCTAssertEqual(destination.base(for: id), before)
        XCTAssertEqual(adapter.text, "one\n\nTWO\n")
    }

    func testNoCredentialMeansNoRequestsAndStaysDirty() async throws {
        let name = "ccp.push.nocred.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([])
        let (adapter, destination) = adapter(store, transport)
        adapter.craftBaseURLOverride = nil
        adapter.craftCredentialUnavailable = true

        adapter.text = "unmapped words"
        await adapter.flushCraftPush()

        XCTAssertTrue(transport.requests.isEmpty,
                      "with no credential the pad stays local-only and silent")
        XCTAssertTrue(adapter.isPushDirty(try XCTUnwrap(adapter.selectedNoteID)),
                      "offline edits wait for a credential instead of clearing")
    }

    /// Lazy provisioning (ccp-0gek): the first push of a non-empty unmapped
    /// pad creates its document (title = pad name), then posts the content
    /// as the empty-doc first sync in the same round.
    func testFirstEditProvisionsDocumentThenPushes() async throws {
        let name = "ccp.push.provision.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([
            .init(statusCode: 200, json: """
                {"items":[{"id":"doc-new","title":"Note 1","clickableLink":"craftdocs://open?x=y"}]}
                """),
            .init(statusCode: 200, json: """
                {"items":[{"id":"b1","markdown":"hello"}]}
                """),
        ])
        transport.documentBlocks = [("b1", "hello")]
        let (adapter, destination) = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)

        adapter.text = "hello"
        await adapter.flushCraftPush()

        XCTAssertEqual(destination.craftDocumentID(for: id), "doc-new")
        XCTAssertEqual(transport.requests.count, 3, "create, post, read-back")
        XCTAssertEqual(transport.requests[0].httpMethod, "POST")
        XCTAssertTrue(transport.requests[0].url?.absoluteString.hasSuffix("/documents") ?? false)
        let createBody = try transport.jsonBody(of: 0)
        XCTAssertEqual((createBody["documents"] as? [[String: String]])?.first?["title"], "Note 1")
        let postBody = try transport.jsonBody(of: 1)
        XCTAssertEqual((postBody["position"] as? [String: String])?["position"], "start")
        XCTAssertEqual((postBody["position"] as? [String: String])?["pageId"], "doc-new")
        XCTAssertFalse(adapter.isPushDirty(id))
        XCTAssertEqual(destination.base(for: id).blocks.map(\.id), ["b1"])
    }

    func testProvisionFailureKeepsDirtyAndUnmapped() async throws {
        let name = "ccp.push.provisionfail.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([.init(statusCode: 500, json: "{}")])
        let (adapter, destination) = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)

        adapter.text = "hello"
        await adapter.flushCraftPush()

        XCTAssertNil(destination.craftDocumentID(for: id),
                     "the mapping lands only on a confirmed create")
        XCTAssertTrue(adapter.isPushDirty(id))
    }

    func testEmptyPadNeverProvisions() async throws {
        let name = "ccp.push.provisionempty.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([])
        let (adapter, destination) = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)

        adapter.text = ""
        await adapter.flushCraftPush()

        XCTAssertTrue(transport.requests.isEmpty,
                      "a document does not exist until the first edit")
        XCTAssertNil(destination.craftDocumentID(for: id))
        XCTAssertFalse(adapter.isPushDirty(id))
    }

    func testWhitespaceOnlyPadNeverProvisions() async throws {
        let name = "ccp.push.provisionblank.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([])
        let (adapter, destination) = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)

        adapter.text = "   \n  "
        await adapter.flushCraftPush()

        XCTAssertTrue(transport.requests.isEmpty,
                      "blank text has no slices, so there is nothing to sync")
        XCTAssertNil(destination.craftDocumentID(for: id))
        XCTAssertFalse(adapter.isPushDirty(id))
    }

    /// Closing a pad while its create is in flight must not resurrect it:
    /// no mapping, no sidecar, and the deleted text never reaches Craft.
    func testCloseDuringProvisionPushesNothing() async throws {
        let name = "ccp.push.provisionclose.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"items":[{"id":"doc-new","title":"Note 1"}]}
            """)])
        let (adapter, destination) = adapter(store, transport)
        let first = try XCTUnwrap(adapter.selectedNoteID)
        adapter.createNote()
        adapter.selectNote(first)

        adapter.text = "doomed words"
        transport.onRequest = {
            await MainActor.run { _ = adapter.deleteNote(first) }
        }
        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 1, "the create fired; nothing followed it")
        XCTAssertNil(destination.craftDocumentID(for: first))
        XCTAssertTrue(destination.base(for: first).blocks.isEmpty)
        XCTAssertFalse(adapter.notes.contains(where: { $0.id == first }))
    }

    /// Backpressure stops the round: pads after a 429 are never attempted.
    func testRateLimitBreaksTheRound() async throws {
        let name = "ccp.push.provision429.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([.init(statusCode: 429, json: "{}",
                                                 headers: ["Retry-After": "45"])])
        let (adapter, destination) = adapter(store, transport)
        let first = try XCTUnwrap(adapter.selectedNoteID)
        adapter.createNote()
        let second = try XCTUnwrap(adapter.selectedNoteID)
        adapter.selectNote(first)
        adapter.text = "one"
        adapter.selectNote(second)
        adapter.text = "two"

        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 1,
                       "the second pad never spends into the throttled window")
        XCTAssertTrue(adapter.isPushDirty(first))
        XCTAssertTrue(adapter.isPushDirty(second))
        XCTAssertTrue(adapter.hasScheduledRetry)
    }

    /// A credential saved mid-round invalidates what the round cleared:
    /// every attempted pad goes again against the new space.
    func testCredentialSwitchRedirtiesTheRound() async throws {
        let name = "ccp.push.switchcred.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([
            .init(statusCode: 200, json: """
                {"items":[{"id":"doc-new","title":"Note 1"}]}
                """),
            .init(statusCode: 200, json: """
                {"items":[{"id":"b1","markdown":"hello"}]}
                """),
        ])
        let (adapter, destination) = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)

        adapter.text = "hello"
        let other = URL(string: "https://connect.craft.do/links/other/api/v1")!
        transport.onRequest = {
            // Once, while the blocks POST is away: the credential switches
            // spaces through the real notification path.
            guard transport.requests.count == 2 else { return }
            await MainActor.run {
                adapter.craftBaseURLOverride = other
                NotificationCenter.default.post(name: .craftCredentialDidChange, object: nil)
            }
        }
        await adapter.flushCraftPush()

        XCTAssertTrue(adapter.isPushDirty(id),
                      "the round wrote to the old space; the new one retries")
    }

    /// Upgrade path: pads written before provisioning existed converge on
    /// the next panel open, without needing an edit in each one.
    func testActivateProvisionsUnmappedNonEmptyPads() async throws {
        let name = "ccp.push.upgrade.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let dir = freshNotesDirectory()
        let first = NotesAdapter(defaults: store, defaultName: "Note", notesDirectory: dir)
        first.craftCredentialUnavailable = true
        first.text = "hello"
        // Let the 800ms save debounce land so the relaunch reads real bytes.
        try await Task.sleep(for: .seconds(1))

        let transport = ScriptedTransport([])
        transport.respond = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/connection") {
                return .init(statusCode: 200, json: """
                    {"space":{"name":"S"},"utc":{"time":"2026-09-05T12:00:00Z"}}
                    """)
            }
            // The trash listing names nothing: without this branch the
            // create echo below would read as trash membership and the
            // settling pull would delete the pad it just provisioned.
            if request.httpMethod == "GET", (request.url?.query ?? "").contains("location=trash") {
                return .init(statusCode: 200, json: "{\"items\":[]}")
            }
            if path.hasSuffix("/documents") {
                return .init(statusCode: 200, json: """
                    {"items":[{"id":"doc-new","title":"Note 1"}]}
                    """)
            }
            return .init(statusCode: 200, json: """
                {"items":[{"id":"b1","markdown":"hello"}]}
                """)
        }
        let destination = CraftNoteDestination(defaults: store)
        let relaunched = NotesAdapter(defaults: store, defaultName: "Note", notesDirectory: dir,
                                      destination: destination)
        relaunched.craftTransport = transport
        relaunched.craftBaseURLOverride = base
        let id = try XCTUnwrap(relaunched.selectedNoteID)

        relaunched.activate()
        await relaunched.flushCraftPush()

        XCTAssertEqual(destination.craftDocumentID(for: id), "doc-new")
        XCTAssertFalse(relaunched.isPushDirty(id))
    }
    func testCredentialSaveDirtiesUnmappedNonEmptyPads() async throws {
        let name = "ccp.push.credsave.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let clock = ScriptedTransport.Script(statusCode: 200, json: """
            {"space":{"name":"S"},"utc":{"time":"2026-09-06T19:00:00Z"}}
            """)
        let transport = ScriptedTransport([
            clock, emptyTrash(), clock, emptyTrash(),
            .init(statusCode: 200, json: """
                {"items":[{"id":"doc-new","title":"Note 1"}]}
                """),
            .init(statusCode: 200, json: """
                {"items":[{"id":"b1","markdown":"hello"}]}
                """),
        ])
        let (adapter, destination) = adapter(store, transport)
        adapter.craftBaseURLOverride = nil
        adapter.craftCredentialUnavailable = true
        let id = try XCTUnwrap(adapter.selectedNoteID)

        adapter.text = "hello"
        await adapter.flushCraftPush()
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(adapter.isPushDirty(id))

        adapter.craftBaseURLOverride = base
        adapter.craftCredentialUnavailable = false
        adapter.activate()
        for _ in 0..<100 where !adapter.isSyncVerified {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(adapter.isSyncVerified, "the panel open verifies")
        NotificationCenter.default.post(name: .craftCredentialDidChange, object: nil)
        // The observer re-verifies on its own task: let that round land
        // before flushing, or the two rounds race the script queue.
        for _ in 0..<100 where !adapter.isSyncVerified {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(adapter.isSyncVerified, "the save re-verifies while open")
        await adapter.flushCraftPush()

        XCTAssertEqual(destination.craftDocumentID(for: id), "doc-new")
        XCTAssertEqual(transport.requests.count, 7,
                       "two clocks, two trash reads, create, post, read-back")
        XCTAssertFalse(adapter.isPushDirty(id))
        adapter.deactivate()
    }

    func testPartialFailureRecordsNothingAndTheRetryFinishes() async throws {
        let name = "ccp.push.partial.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        // PUT ok, DELETE 500s. Then everything ok.
        let transport = ScriptedTransport([
            emptyTrash(),
            .init(statusCode: 200, json: """
                {"items":[{"id":"block-1","markdown":"TWO!"}]}
                """),
            .init(statusCode: 500, json: "{}"),
            emptyTrash(),
            .init(statusCode: 200, json: """
                {"items":[{"id":"block-1","markdown":"TWO!"}]}
                """),
            .init(statusCode: 200, json: "{}"),
            .init(statusCode: 200, json: """
                {"items":[{"id":"block-0","markdown":"one"},{"id":"block-1","markdown":"TWO!"}]}
                """),
        ])
        let (adapter, destination) = adapter(store, transport)
        let id = try seed(adapter, destination, text: "one\n\ntwo\n\nthree\n")
        let before = destination.base(for: id)

        adapter.text = "one\n\nTWO\n"
        // Drop "three": update plus delete in one plan.
        await adapter.flushCraftPush()

        XCTAssertEqual(destination.base(for: id), before,
                       "half a round is not an agreement — nothing is recorded")
        XCTAssertTrue(adapter.isPushDirty(id))

        await adapter.flushCraftPush()

        XCTAssertEqual(destination.base(for: id).blocks.map(\.id), ["block-0", "block-1"],
                       "the retry replans the same diff and finishes it")
        XCTAssertEqual(destination.base(for: id).localText, "one\n\nTWO\n")
        XCTAssertFalse(adapter.isPushDirty(id))
        XCTAssertEqual(transport.requests.count, 7,
                       "sweep, PUT, DELETE-fail, then sweep, PUT, DELETE-ok, read-back")
    }

    func testMixedAnchorsPostOneBatchEach() async throws {
        let name = "ccp.push.groups.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([
            emptyTrash(),
            .init(statusCode: 200, json: """
                {"items":[{"id":"block-0","markdown":"A"}]}
                """),
            .init(statusCode: 200, json: """
                {"items":[{"id":"nx","markdown":"x"}]}
                """),
            .init(statusCode: 200, json: """
                {"items":[{"id":"ny","markdown":"y"}]}
                """),
        ])
        transport.documentBlocks = [("block-0", "A"), ("nx", "x"), ("block-1", "b"),
                                    ("block-2", "c"), ("ny", "y")]
        let (adapter, destination) = adapter(store, transport)
        let id = try seed(adapter, destination, text: "a\n\nb\n\nc\n")

        adapter.text = "A\n\nx\n\nb\n\nc\n\ny\n"
        await adapter.flushCraftPush()

        let methods = transport.requests.map { $0.httpMethod }
        XCTAssertEqual(methods, ["GET", "PUT", "POST", "POST", "GET"],
                       "sweep, one PUT, one POST per anchor, then the read-back")
        XCTAssertEqual(destination.base(for: id).blocks.map(\.id),
                       ["block-0", "nx", "block-1", "block-2", "ny"],
                       "new ids land in pad order")
    }

    func testPrependPostsAtEndThenMovesBeforeTheHeadBlock() async throws {
        let name = "ccp.push.prepend.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([
            emptyTrash(),
            .init(statusCode: 200, json: """
                {"items":[{"id":"na","markdown":"A"}]}
                """),
            .init(statusCode: 200, json: """
                {"items":[{"id":"na"}]}
                """),
            .init(statusCode: 200, json: """
                {"items":[{"id":"nc","markdown":"c"}]}
                """),
        ])
        transport.documentBlocks = [("na", "A"), ("block-0", "B"), ("nc", "c")]
        let (adapter, destination) = adapter(store, transport)
        let id = try seed(adapter, destination, text: "B\n")

        // A has no anchor (head of the pad) but c anchors to B.
        adapter.text = "A\n\nB\n\nc\n"
        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 5,
                       "sweep, head group posts and moves, anchored group posts, read-back")
        let postPosition = try XCTUnwrap(
            (try transport.jsonBody(of: 1)["position"] as? [String: String]))
        XCTAssertEqual(postPosition["position"], "end",
                       "the anchorless group lands at the end, where appends stay separate")
        XCTAssertEqual(postPosition["pageId"], "doc1")
        XCTAssertEqual(transport.requests[2].httpMethod, "PUT")
        let moveBody = try transport.jsonBody(of: 2)
        XCTAssertEqual(moveBody["blockIds"] as? [String], ["na"])
        let movePosition = try XCTUnwrap(moveBody["position"] as? [String: String])
        XCTAssertEqual(movePosition["position"], "before")
        XCTAssertEqual(movePosition["siblingId"], "block-0")
        XCTAssertEqual(destination.base(for: id).blocks.map(\.id), ["na", "block-0", "nc"],
                       "new ids land in pad order")
        XCTAssertFalse(adapter.isPushDirty(id), "nothing stalls anymore")
    }

    func testRetrySurvivesANewEdit() async throws {
        let name = "ccp.push.retrysurvives.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([.init(statusCode: 500, json: "{}")])
        let (adapter, destination) = adapter(store, transport)
        _ = try seed(adapter, destination, text: "one\n\ntwo\n")

        adapter.text = "one\n\nTWO\n"
        await adapter.flushCraftPush()
        XCTAssertTrue(adapter.hasScheduledRetry)

        // The R2 regression: scheduling the debounce used to cancel this.
        adapter.text = "one\n\nTWO!\n"
        XCTAssertTrue(adapter.hasScheduledRetry,
                      "an edit during backoff must not eat the only scheduled healing")
    }

    func testFlushPushesEveryDirtyPad() async throws {
        let name = "ccp.push.multipad.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([])
        // Echo each PUT back with its own id, canonically spelled, whatever
        // order the dirty set pushes in. The pre-write sweep's trash read
        // carries no body and names nothing trashed.
        transport.respond = { request in
            // The read-back that records the agreement answers with the
            // canonical text for the pad it names.
            if request.httpMethod == "GET", let url = request.url?.absoluteString,
               let word = ["aaa", "bbb"].first(where: { url.contains("doc-\($0)") }) {
                return ScriptedTransport.Script(statusCode: 200, json:
                    "{\"items\":[{\"id\":\"\(word)-0\",\"markdown\":\"\(word.uppercased())!\"}]}")
            }
            guard let bodyData = request.httpBody,
                  let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            else {
                return ScriptedTransport.Script(statusCode: 200, json: "{\"items\":[]}")
            }
            let blocks = (body["blocks"] as? [[String: String]]) ?? []
            let echo = blocks.map { "{\"id\":\"\($0["id"]!)\",\"markdown\":\"\($0["markdown"]!)!\"}" }
                .joined(separator: ",")
            return ScriptedTransport.Script(statusCode: 200, json: "{\"items\":[\(echo)]}")
        }
        let (adapter, destination) = adapter(store, transport)
        adapter.createNote()
        let first = adapter.notes[0].id
        let second = adapter.notes[1].id
        for (id, word) in [(first, "aaa"), (second, "bbb")] {
            destination.storeBase(.fixture(word, ids: ["\(word)-0"]), for: id)
            destination.setCraftDocumentID("doc-\(word)", for: id)
            destination.storeSyncedTitle(adapter.notes.first(where: { $0.id == id })?.name, for: id)
        }

        adapter.selectNote(first)
        adapter.text = "AAA"
        adapter.selectNote(second)
        adapter.text = "BBB"
        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 5,
                       "sweep plus both dirty pads pushing and reading back")
        let putIDs = Set(transport.requests.flatMap { request -> [String] in
            guard let httpBody = request.httpBody,
                  let body = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any]
            else { return [] }
            return ((body["blocks"] as? [[String: String]]) ?? []).compactMap { $0["id"] }
        })
        XCTAssertEqual(putIDs, ["aaa-0", "bbb-0"])
        XCTAssertEqual(destination.base(for: first).blocks.map(\.markdown), ["AAA!"])
        XCTAssertEqual(destination.base(for: second).blocks.map(\.markdown), ["BBB!"])
    }

    func testBackgroundPadPushLeavesTheVisiblePadAlone() async throws {
        let name = "ccp.push.background.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([emptyTrash(), .init(statusCode: 200, json: """
            {"items":[{"id":"a0","markdown":"AAA!"}]}
            """)])
        transport.documentBlocks = [("a0", "AAA!")]
        let (adapter, destination) = adapter(store, transport)
        adapter.createNote()
        let first = adapter.notes[0].id
        destination.storeBase(.fixture("aaa", ids: ["a0"]), for: first)
        destination.setCraftDocumentID("doc-aaa", for: first)
        destination.storeSyncedTitle(adapter.notes.first(where: { $0.id == first })?.name, for: first)

        // Edit A, then switch away before the push fires.
        adapter.selectNote(first)
        adapter.text = "AAA"
        adapter.selectNote(adapter.notes[1].id)
        await adapter.flushCraftPush()

        XCTAssertEqual(adapter.text, "", "the visible pad is untouched")
        XCTAssertEqual(adapter.notes.first(where: { $0.id == first })?.text, "AAA",
                       "no push ever rewrites a pad")
        XCTAssertEqual(destination.base(for: first).blocks.map(\.markdown), ["AAA!"],
                       "the base still learns what Craft holds")
    }

    func testRepeatedFailureThrottlesDebouncedRuns() async throws {
        let name = "ccp.push.throttle.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport(
            (0..<6).map { _ in ScriptedTransport.Script(statusCode: 500, json: "{}") })
        let (adapter, destination) = adapter(store, transport)
        _ = try seed(adapter, destination, text: "one\n\ntwo\n")

        adapter.text = "one\n\nTWO\n"
        for _ in 0..<4 { await adapter.flushCraftPush() }
        XCTAssertTrue(adapter.isPushThrottled, "three retries then give up until the window passes")
    }

    func testClosingANoteDropsItsDocumentMapping() async throws {
        let name = "ccp.push.mapdrop.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let destination = CraftNoteDestination(defaults: store)
        let adapter = NotesAdapter(defaults: store, defaultName: "Note",
                                   notesDirectory: freshNotesDirectory(),
                                   destination: destination)
        adapter.createNote()
        let doomed = adapter.notes[0].id

        destination.setCraftDocumentID("doc9", for: doomed)
        XCTAssertTrue(adapter.deleteNote(doomed))
        XCTAssertNil(destination.craftDocumentID(for: doomed))
    }
}
