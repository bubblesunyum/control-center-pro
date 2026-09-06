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

/// The rebuild half: only confirmed units enter the sidecar, echoes pair by
/// id (PUT) and order (POST), and the write-back carries the canonical
/// spelling with its guard text.
final class CraftPushRebuildTests: XCTestCase {
    private func slice(_ markdown: String) -> CraftBlockSlice {
        CraftBlockSlice(markdown: markdown, range: NSRange(location: 0, length: 0))
    }

    private func sliced(_ text: String) -> [CraftBlockSlice] {
        CraftBlockSplitter.slices(in: text)
    }

    private func seeded(_ markdowns: [String]) -> BlockSidecar {
        BlockSidecar(entries: markdowns.enumerated().map { index, markdown in
            BlockSidecarEntry(id: "block-\(index)",
                              fingerprint: BlockSidecar.fingerprint(markdown))
        })
    }

    func testConfirmedUpdateRecordsCanonicalFingerprint() {
        let sidecar = seeded(["one", "two"])
        let slices = sliced("one\n\nTWO\n")
        let rebuilt = sidecar.applyingPush(
            text: "one\n\nTWO\n",
            slices: slices,
            putEcho: [CraftBlock(id: "block-1", markdown: "TWO!")],
            postEchoByInsert: [:],
            deletesConfirmed: true)

        XCTAssertEqual(rebuilt.entries.map(\.id), ["block-0", "block-1"])
        XCTAssertEqual(rebuilt.entries[1].fingerprint,
                       BlockSidecar.fingerprint("TWO!"))
        // Quiet next round: the canonical text now diffs clean.
        XCTAssertTrue(rebuilt.pushPlan(for: [slice("one"), slice("TWO!")]).isEmpty)
    }

    func testMissingPutEchoKeepsTheOldEntryForRetry() {
        let sidecar = seeded(["one", "two"])
        let rebuilt = sidecar.applyingPush(
            text: "one\n\nTWO\n",
            slices: sliced("one\n\nTWO\n"),
            putEcho: [],
            postEchoByInsert: [:],
            deletesConfirmed: true)

        XCTAssertEqual(rebuilt, sidecar)
        // Still diffs as an update next round.
        XCTAssertEqual(rebuilt.pushPlan(for: sliced("one\n\nTWO\n")).updates.map(\.id),
                       ["block-1"])
    }

    func testPostEchoBecomesOrderedEntries() {
        let rebuilt = BlockSidecar().applyingPush(
            text: "one\n\ntwo\n",
            slices: sliced("one\n\ntwo\n"),
            putEcho: [],
            postEchoByInsert: [
                        0: [CraftBlock(id: "n1", markdown: "one")],
                        1: [CraftBlock(id: "n2", markdown: "two")]
                       ],
            deletesConfirmed: true)

        XCTAssertEqual(rebuilt.entries.map(\.id), ["n1", "n2"])
        XCTAssertTrue(rebuilt.pushPlan(for: sliced("one\n\ntwo\n")).isEmpty)
    }

    func testSplitEchoStaysInsideItsGroup() {
        let rebuilt = BlockSidecar().applyingPush(
            text: "one\n\ntwo\n",
            slices: sliced("one\n\ntwo\n"),
            putEcho: [],
            postEchoByInsert: [
                        0: [CraftBlock(id: "n1", markdown: "one")],
                        1: [CraftBlock(id: "n2a", markdown: "two"),
                            CraftBlock(id: "n2b", markdown: "more")]
                       ],
            deletesConfirmed: true)

        XCTAssertEqual(rebuilt.entries.map(\.id), ["n1", "n2a", "n2b"])
    }

    func testSplitInOneGroupNeverCrossWiresAnother() {
        // A splits server-side, B does not, different anchors. B's entry
        // must fingerprint B's text exactly — positional pairing across
        // groups used to hand B the split's tail.
        let sidecar = seeded(["x", "y"])
        let rebuilt = sidecar.applyingPush(
            text: "x\n\nA\n\ny\n\nB\n",
            slices: sliced("x\n\nA\n\ny\n\nB\n"),
            putEcho: [],
            postEchoByInsert: [
                        0: [CraftBlock(id: "a1", markdown: "A1"),
                            CraftBlock(id: "a2", markdown: "A2")],
                        1: [CraftBlock(id: "b1", markdown: "B")]
                       ],
            deletesConfirmed: true)

        XCTAssertEqual(rebuilt.entries.map(\.id),
                       ["block-0", "a1", "a2", "block-1", "b1"])
        XCTAssertEqual(rebuilt.entries[4].fingerprint, BlockSidecar.fingerprint("B"))
    }

    func testTightListEchoKeepsBothItems() {
        // Same-anchor batch of two list items, echo identical.
        let rebuilt = BlockSidecar().applyingPush(
            text: "- a\n- b\n",
            slices: sliced("- a\n- b\n"),
            putEcho: [],
            postEchoByInsert: [
                        0: [CraftBlock(id: "na", markdown: "- a")],
                        1: [CraftBlock(id: "nb", markdown: "- b")]
                       ],
            deletesConfirmed: true)

        XCTAssertEqual(rebuilt.entries.map(\.id), ["na", "nb"])
        XCTAssertTrue(rebuilt.pushPlan(for: sliced("- a\n- b\n")).isEmpty)
    }

    func testFailedPostLeavesInsertsAbsent() {
        let rebuilt = BlockSidecar().applyingPush(
            text: "one\n",
            slices: sliced("one\n"),
            putEcho: [],
            postEchoByInsert: [:],
            deletesConfirmed: true)

        XCTAssertTrue(rebuilt.entries.isEmpty)
        XCTAssertEqual(rebuilt.pushPlan(for: sliced("one\n")).inserts.map(\.markdown),
                       ["one"])
    }

    func testSplitEchoRebuildsPadOrderExactly() {
        // [AAA, B] splits server-side into [a1, a2, b1]. The rebuild pairs
        // positionally, so values and order are exact whatever the split
        // boundaries were.
        let rebuilt = BlockSidecar().applyingPush(
            text: "AAA\n\nB\n",
            slices: sliced("AAA\n\nB\n"),
            putEcho: [],
            postEchoByInsert: [
                        0: [CraftBlock(id: "a1", markdown: "a1"),
                            CraftBlock(id: "a2", markdown: "a2")],
                        1: [CraftBlock(id: "b1", markdown: "b1")]
                       ],
            deletesConfirmed: true)

        XCTAssertEqual(rebuilt.entries.map(\.id), ["a1", "a2", "b1"])

        // Convergence: the recorded entries re-split 1:1, so the next round
        // is silent. A split can churn ids once, never miswire them.
        let converged = "a1\n\na2\n\nb1\n"
        XCTAssertTrue(rebuilt.pushPlan(for: CraftBlockSplitter.slices(in: converged)).isEmpty)
    }

    func testConfirmedDeleteDropsEntries() {
        let sidecar = seeded(["one", "two"])
        let rebuilt = sidecar.applyingPush(
            text: "two\n",
            slices: sliced("two\n"),
            putEcho: [],
            postEchoByInsert: [:],
            deletesConfirmed: true)
        XCTAssertEqual(rebuilt.entries.map(\.id), ["block-1"])
    }

    func testUnconfirmedDeleteRestoresEntries() {
        let sidecar = seeded(["one", "two"])
        let rebuilt = sidecar.applyingPush(
            text: "two\n",
            slices: sliced("two\n"),
            putEcho: [],
            postEchoByInsert: [:],
            deletesConfirmed: false)
        XCTAssertEqual(Set(rebuilt.entries.map(\.id)), ["block-0", "block-1"],
                       "order may shift on restore; the next diff absorbs it as churn")
        // And the retry drops it exactly.
        let retried = rebuilt.applyingPush(
            text: "two\n",
            slices: sliced("two\n"),
            putEcho: [],
            postEchoByInsert: [:],
            deletesConfirmed: true)
        XCTAssertEqual(retried.entries.map(\.id), ["block-1"])
    }

    func testPinnedEntrySurvivesEvenAConfirmedDelete() {
        let sidecar = BlockSidecar(entries: [
            BlockSidecarEntry(id: "a", fingerprint: BlockSidecar.fingerprint("one")),
            BlockSidecarEntry(id: "b", fingerprint: BlockSidecar.fingerprint("two"),
                              isWritable: false),
        ])
        let rebuilt = sidecar.applyingPush(
            text: "one\n",
            slices: sliced("one\n"),
            putEcho: [],
            postEchoByInsert: [:],
            deletesConfirmed: true)
        XCTAssertTrue(rebuilt.entries.contains(where: { $0.id == "b" }),
                      "a pinned block is never deleted, whatever the request said")
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
        let map = DefaultsMap<BlockSidecar>(defaults: store, key: "test.map")

        XCTAssertTrue(map.load().isEmpty)
        let sidecar = BlockSidecar(entries: [BlockSidecarEntry(id: "b1", fingerprint: "f")])
        map.set(sidecar, for: "pad")
        XCTAssertEqual(map.load()["pad"], sidecar)
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

        let map = DefaultsMap<BlockSidecar>(defaults: store, key: "test.map")
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

        let map = DefaultsMap<BlockSidecar>(defaults: store, key: "test.map")
        XCTAssertTrue(map.load().isEmpty)
        XCTAssertFalse(map.hasUndecodableBytes, "valid empty JSON must not arm the rescue")
    }
}

/// The adapter half: flush spends the plan end to end, stores the confirmed
/// sidecar, and folds the write-back in only behind the flag and the guard.
@MainActor
final class CraftPushAdapterTests: XCTestCase {
    private let base = URL(string: "https://connect.craft.do/links/test/api/v1")!

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

    private func seed(_ adapter: NotesAdapter, text: String) throws -> UUID {
        let id = try XCTUnwrap(adapter.selectedNoteID)
        adapter.storeSidecar(
            BlockSidecar(entries: CraftBlockSplitter.slices(in: text).enumerated().map { index, slice in
                BlockSidecarEntry(id: "block-\(index)",
                                  fingerprint: BlockSidecar.fingerprint(slice.markdown))
            }), for: id)
        adapter.setCraftDocumentID("doc1", for: id)
        return id
    }

    func testFlushPutsTheEditAndStoresTheEcho() async throws {
        let name = "ccp.push.flush.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"items":[{"id":"block-1","markdown":"TWO!"}]}
            """)])
        let adapter = adapter(store, transport)
        let id = try seed(adapter, text: "one\n\ntwo\n")

        adapter.text = "one\n\nTWO\n"
        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 1, "one PUT, nothing else")
        XCTAssertEqual(adapter.sidecar(for: id).entries[1].fingerprint,
                       BlockSidecar.fingerprint("TWO!"))
        XCTAssertEqual(adapter.text, "one\n\nTWO\n",
                       "a push never rewrites the pad — the user's spelling stands")
    }

    func testMidFlightTypingStaysDirtyForAnotherRound() async throws {
        let name = "ccp.push.midflight.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([
            .init(statusCode: 200, json: """
                {"items":[{"id":"block-1","markdown":"TWO!"}]}
                """),
            .init(statusCode: 200, json: """
                {"items":[{"id":"block-1","markdown":"TW0!"}]}
                """),
        ])
        let adapter = adapter(store, transport)
        let id = try seed(adapter, text: "one\n\ntwo\n")

        adapter.text = "one\n\nTWO\n"
        transport.onRequest = {
            // The user retyped the pushed block while the PUT was away.
            await MainActor.run { adapter.text = "one\n\nTW0\n" }
        }
        await adapter.flushCraftPush()

        XCTAssertEqual(adapter.text, "one\n\nTW0\n", "the pad is never rewritten by a push")
        XCTAssertTrue(adapter.isPushDirty(id),
                      "the sidecar describes the pushed text, not the current text")

        await adapter.flushCraftPush()
        XCTAssertFalse(adapter.isPushDirty(id))
        XCTAssertEqual(adapter.sidecar(for: id).entries[1].fingerprint,
                       BlockSidecar.fingerprint("TW0!"))
        XCTAssertEqual(adapter.text, "one\n\nTW0\n")
    }

    func testFailureLeavesTheSidecarUntouched() async throws {
        let name = "ccp.push.failure.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([.init(statusCode: 500, json: "{}")])
        let adapter = adapter(store, transport)
        let id = try seed(adapter, text: "one\n\ntwo\n")
        let before = adapter.sidecar(for: id)

        adapter.text = "one\n\nTWO\n"
        await adapter.flushCraftPush()

        XCTAssertEqual(adapter.sidecar(for: id), before)
        XCTAssertEqual(adapter.text, "one\n\nTWO\n")
    }

    func testNoCredentialMeansNoRequestsAndStaysDirty() async throws {
        let name = "ccp.push.nocred.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([])
        let adapter = adapter(store, transport)
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
        let adapter = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)

        adapter.text = "hello"
        await adapter.flushCraftPush()

        XCTAssertEqual(adapter.craftDocumentID(for: id), "doc-new")
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0].httpMethod, "POST")
        XCTAssertTrue(transport.requests[0].url?.absoluteString.hasSuffix("/documents") ?? false)
        let createBody = try transport.jsonBody(of: 0)
        XCTAssertEqual((createBody["documents"] as? [[String: String]])?.first?["title"], "Note 1")
        let postBody = try transport.jsonBody(of: 1)
        XCTAssertEqual((postBody["position"] as? [String: String])?["position"], "start")
        XCTAssertEqual((postBody["position"] as? [String: String])?["pageId"], "doc-new")
        XCTAssertFalse(adapter.isPushDirty(id))
        XCTAssertEqual(adapter.sidecar(for: id).entries.map(\.id), ["b1"])
    }

    func testProvisionFailureKeepsDirtyAndUnmapped() async throws {
        let name = "ccp.push.provisionfail.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([.init(statusCode: 500, json: "{}")])
        let adapter = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)

        adapter.text = "hello"
        await adapter.flushCraftPush()

        XCTAssertNil(adapter.craftDocumentID(for: id),
                     "the mapping lands only on a confirmed create")
        XCTAssertTrue(adapter.isPushDirty(id))
    }

    func testEmptyPadNeverProvisions() async throws {
        let name = "ccp.push.provisionempty.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([])
        let adapter = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)

        adapter.text = ""
        await adapter.flushCraftPush()

        XCTAssertTrue(transport.requests.isEmpty,
                      "a document does not exist until the first edit")
        XCTAssertNil(adapter.craftDocumentID(for: id))
        XCTAssertFalse(adapter.isPushDirty(id))
    }

    func testWhitespaceOnlyPadNeverProvisions() async throws {
        let name = "ccp.push.provisionblank.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([])
        let adapter = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)

        adapter.text = "   \n  "
        await adapter.flushCraftPush()

        XCTAssertTrue(transport.requests.isEmpty,
                      "blank text has no slices, so there is nothing to sync")
        XCTAssertNil(adapter.craftDocumentID(for: id))
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
        let adapter = adapter(store, transport)
        let first = try XCTUnwrap(adapter.selectedNoteID)
        adapter.createNote()
        adapter.selectNote(first)

        adapter.text = "doomed words"
        transport.onRequest = {
            await MainActor.run { _ = adapter.closeNote(first) }
        }
        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 1, "the create fired; nothing followed it")
        XCTAssertNil(adapter.craftDocumentID(for: first))
        XCTAssertTrue(adapter.sidecar(for: first).entries.isEmpty)
        XCTAssertFalse(adapter.notes.contains(where: { $0.id == first }))
    }

    /// Backpressure stops the round: pads after a 429 are never attempted.
    func testRateLimitBreaksTheRound() async throws {
        let name = "ccp.push.provision429.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([.init(statusCode: 429, json: "{}",
                                                 headers: ["Retry-After": "45"])])
        let adapter = adapter(store, transport)
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
        let adapter = adapter(store, transport)
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
        let first = NotesAdapter(defaults: store, defaultName: "Note")
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
            if path.hasSuffix("/documents") {
                return .init(statusCode: 200, json: """
                    {"items":[{"id":"doc-new","title":"Note 1"}]}
                    """)
            }
            return .init(statusCode: 200, json: """
                {"items":[{"id":"b1","markdown":"hello"}]}
                """)
        }
        let relaunched = NotesAdapter(defaults: store, defaultName: "Note")
        relaunched.craftTransport = transport
        relaunched.craftBaseURLOverride = base
        let id = try XCTUnwrap(relaunched.selectedNoteID)

        relaunched.activate()
        await relaunched.flushCraftPush()

        XCTAssertEqual(relaunched.craftDocumentID(for: id), "doc-new")
        XCTAssertFalse(relaunched.isPushDirty(id))
    }
    func testCredentialSaveDirtiesUnmappedNonEmptyPads() async throws {
        let name = "ccp.push.credsave.\(UUID().uuidString)"
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
        let adapter = adapter(store, transport)
        adapter.craftBaseURLOverride = nil
        adapter.craftCredentialUnavailable = true
        let id = try XCTUnwrap(adapter.selectedNoteID)

        adapter.text = "hello"
        await adapter.flushCraftPush()
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(adapter.isPushDirty(id))

        adapter.craftBaseURLOverride = base
        adapter.craftCredentialUnavailable = false
        NotificationCenter.default.post(name: .craftCredentialDidChange, object: nil)
        await adapter.flushCraftPush()

        XCTAssertEqual(adapter.craftDocumentID(for: id), "doc-new")
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertFalse(adapter.isPushDirty(id))
    }

    func testPartialFailureStoresConfirmedUnits() async throws {
        let name = "ccp.push.partial.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        // PUT ok, DELETE 500s. Then everything ok.
        let transport = ScriptedTransport([
            .init(statusCode: 200, json: """
                {"items":[{"id":"block-1","markdown":"TWO!"}]}
                """),
            .init(statusCode: 500, json: "{}"),
            .init(statusCode: 200, json: """
                {"items":[{"id":"block-1","markdown":"TWO!"}]}
                """),
            .init(statusCode: 200, json: "{}"),
        ])
        let adapter = adapter(store, transport)
        let id = try seed(adapter, text: "one\n\ntwo\n\nthree\n")

        adapter.text = "one\n\nTWO\n"
        // Drop "three": update + delete in one plan.
        await adapter.flushCraftPush()

        // The PUT half is stored; the delete is restored for retry.
        XCTAssertEqual(adapter.sidecar(for: id).entries.map(\.id),
                       ["block-0", "block-1", "block-2"])
        XCTAssertEqual(adapter.sidecar(for: id).entries[1].fingerprint,
                       BlockSidecar.fingerprint("TWO!"))

        await adapter.flushCraftPush()
        XCTAssertEqual(adapter.sidecar(for: id).entries.map(\.id), ["block-0", "block-1"],
                       "retry drops the delete without re-posting anything")
        XCTAssertEqual(transport.requests.count, 4, "PUT, DELETE-fail, PUT, DELETE-ok")
    }

    func testMixedAnchorsPostOneBatchEach() async throws {
        let name = "ccp.push.groups.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([
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
        let adapter = adapter(store, transport)
        let id = try seed(adapter, text: "a\n\nb\n\nc\n")

        adapter.text = "A\n\nx\n\nb\n\nc\n\ny\n"
        await adapter.flushCraftPush()

        let methods = transport.requests.map { $0.httpMethod }
        XCTAssertEqual(methods, ["PUT", "POST", "POST"])
        XCTAssertEqual(adapter.sidecar(for: id).entries.map(\.id),
                       ["block-0", "nx", "block-1", "block-2", "ny"],
                       "new ids land in pad order")
    }

    func testPrependPostsAtEndThenMovesBeforeTheHeadBlock() async throws {
        let name = "ccp.push.prepend.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([
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
        let adapter = adapter(store, transport)
        let id = try seed(adapter, text: "B\n")

        // A has no anchor (head of the pad) but c anchors to B.
        adapter.text = "A\n\nB\n\nc\n"
        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 3, "head group posts and moves, anchored group posts")
        let postPosition = try XCTUnwrap(
            (try transport.jsonBody(of: 0)["position"] as? [String: String]))
        XCTAssertEqual(postPosition["position"], "end",
                       "the anchorless group lands at the end, where appends stay separate")
        XCTAssertEqual(postPosition["pageId"], "doc1")
        XCTAssertEqual(transport.requests[1].httpMethod, "PUT")
        let moveBody = try transport.jsonBody(of: 1)
        XCTAssertEqual(moveBody["blockIds"] as? [String], ["na"])
        let movePosition = try XCTUnwrap(moveBody["position"] as? [String: String])
        XCTAssertEqual(movePosition["position"], "before")
        XCTAssertEqual(movePosition["siblingId"], "block-0")
        XCTAssertEqual(adapter.sidecar(for: id).entries.map(\.id), ["na", "block-0", "nc"],
                       "new ids land in pad order")
        XCTAssertFalse(adapter.isPushDirty(id), "nothing stalls anymore")
    }

    func testRetrySurvivesANewEdit() async throws {
        let name = "ccp.push.retrysurvives.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([.init(statusCode: 500, json: "{}")])
        let adapter = adapter(store, transport)
        _ = try seed(adapter, text: "one\n\ntwo\n")

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
        // order the dirty set pushes in.
        transport.respond = { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                ?? [:]
            let blocks = (body["blocks"] as? [[String: String]]) ?? []
            let echo = blocks.map { "{\"id\":\"\($0["id"]!)\",\"markdown\":\"\($0["markdown"]!)!\"}" }
                .joined(separator: ",")
            return ScriptedTransport.Script(statusCode: 200, json: "{\"items\":[\(echo)]}")
        }
        let adapter = adapter(store, transport)
        adapter.createNote()
        let first = adapter.notes[0].id
        let second = adapter.notes[1].id
        for (id, word) in [(first, "aaa"), (second, "bbb")] {
            adapter.storeSidecar(
                BlockSidecar(entries: [BlockSidecarEntry(id: "\(word)-0",
                    fingerprint: BlockSidecar.fingerprint(word))]), for: id)
            adapter.setCraftDocumentID("doc-\(word)", for: id)
        }

        adapter.selectNote(first)
        adapter.text = "AAA"
        adapter.selectNote(second)
        adapter.text = "BBB"
        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 2, "both dirty pads push, not just the selected one")
        let putIDs = Set(transport.requests.flatMap { request -> [String] in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]) ?? [:]
            return ((body["blocks"] as? [[String: String]]) ?? []).compactMap { $0["id"] }
        })
        XCTAssertEqual(putIDs, ["aaa-0", "bbb-0"])
        XCTAssertEqual(adapter.sidecar(for: first).entries.map(\.fingerprint),
                       [BlockSidecar.fingerprint("AAA!")])
        XCTAssertEqual(adapter.sidecar(for: second).entries.map(\.fingerprint),
                       [BlockSidecar.fingerprint("BBB!")])
    }

    func testBackgroundPadPushLeavesTheVisiblePadAlone() async throws {
        let name = "ccp.push.background.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"items":[{"id":"a0","markdown":"AAA!"}]}
            """)])
        let adapter = adapter(store, transport)
        adapter.createNote()
        let first = adapter.notes[0].id
        adapter.storeSidecar(
            BlockSidecar(entries: [BlockSidecarEntry(id: "a0",
                fingerprint: BlockSidecar.fingerprint("aaa"))]), for: first)
        adapter.setCraftDocumentID("doc-aaa", for: first)

        // Edit A, then switch away before the push fires.
        adapter.selectNote(first)
        adapter.text = "AAA"
        adapter.selectNote(adapter.notes[1].id)
        await adapter.flushCraftPush()

        XCTAssertEqual(adapter.text, "", "the visible pad is untouched")
        XCTAssertEqual(adapter.notes.first(where: { $0.id == first })?.text, "AAA",
                       "no push ever rewrites a pad")
        XCTAssertEqual(adapter.sidecar(for: first).entries.map(\.fingerprint),
                       [BlockSidecar.fingerprint("AAA!")],
                       "the sidecar still learns the canonical form")
    }

    func testRepeatedFailureThrottlesDebouncedRuns() async throws {
        let name = "ccp.push.throttle.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport(
            (0..<6).map { _ in ScriptedTransport.Script(statusCode: 500, json: "{}") })
        let adapter = adapter(store, transport)
        _ = try seed(adapter, text: "one\n\ntwo\n")

        adapter.text = "one\n\nTWO\n"
        for _ in 0..<4 { await adapter.flushCraftPush() }
        XCTAssertTrue(adapter.isPushThrottled, "three retries then give up until the window passes")
    }

    func testClosingANoteDropsItsDocumentMapping() async throws {
        let name = "ccp.push.mapdrop.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let adapter = NotesAdapter(defaults: store, defaultName: "Note")
        adapter.createNote()
        let doomed = adapter.notes[0].id

        adapter.setCraftDocumentID("doc9", for: doomed)
        XCTAssertTrue(adapter.closeNote(doomed))
        XCTAssertNil(adapter.craftDocumentID(for: doomed))
    }
}
