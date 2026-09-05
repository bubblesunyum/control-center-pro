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
/// and the failure mapping. Shapes here are the documented ones; the vendor
/// excerpt (ccp-2zi.5) confirms the rest before this closes.
final class CraftPushWireTests: XCTestCase {
    private let base = URL(string: "https://connect.craft.do/links/test/api/v1")!

    private func client(_ transport: ScriptedTransport) -> CraftClient {
        CraftClient(baseURL: base, transport: transport)
    }

    func testPutSendsBatchedUpdatesAndReadsTheEnvelopeEcho() async throws {
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"blocks":[{"id":"b1","markdown":"TWO!","type":"text"}]}
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

    func testPostWithoutAnchorGoesToEndOfDocument() async throws {
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"blocks":[{"id":"n1","markdown":"one"}]}
            """)])
        _ = try await client(transport).postBlocks(
            [BlockInsert(afterID: nil, markdown: "one")], documentID: "doc1")

        let body = try transport.jsonBody(of: 0)
        let position = try XCTUnwrap(body["position"] as? [String: String])
        XCTAssertEqual(position["position"], "end")
        XCTAssertEqual(position["pageId"], "doc1")
        let blocks = try XCTUnwrap(body["blocks"] as? [[String: String]])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0]["type"], "text")
        XCTAssertEqual(blocks[0]["markdown"], "one")
    }

    func testPostWithAnchorFollowsTheSibling() async throws {
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"blocks":[{"id":"n1","markdown":"new"}]}
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
            {"blocks":[{"id":"n1","markdown":"x"}]}
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

    func testConfirmedUpdateRecordsCanonicalFingerprintAndWriteBack() {
        let sidecar = seeded(["one", "two"])
        let slices = sliced("one\n\nTWO\n")
        let (rebuilt, writeBack) = sidecar.applyingPush(
            text: "one\n\nTWO\n",
            slices: slices,
            putEcho: [CraftBlock(id: "block-1", markdown: "TWO!")],
            postEchoByInsert: [:],
            deletesConfirmed: true)

        XCTAssertEqual(rebuilt.entries.map(\.id), ["block-0", "block-1"])
        XCTAssertEqual(rebuilt.entries[1].fingerprint,
                       BlockSidecar.fingerprint("TWO!"))
        XCTAssertEqual(writeBack.count, 1)
        XCTAssertEqual(writeBack[0].prior, "TWO")
        XCTAssertEqual(writeBack[0].markdown, "TWO!")
        // Quiet next round: the canonical text now diffs clean.
        XCTAssertTrue(rebuilt.pushPlan(for: [slice("one"), slice("TWO!")]).isEmpty)
    }

    func testIdenticalEchoSkipsTheWriteBack() {
        let sidecar = seeded(["one", "two"])
        let (_, writeBack) = sidecar.applyingPush(
            text: "one\n\nTWO\n",
            slices: sliced("one\n\nTWO\n"),
            putEcho: [CraftBlock(id: "block-1", markdown: "TWO")],
            postEchoByInsert: [:],
            deletesConfirmed: true)
        XCTAssertTrue(writeBack.isEmpty, "nothing changed, nothing to write back")
    }

    func testMissingPutEchoKeepsTheOldEntryForRetry() {
        let sidecar = seeded(["one", "two"])
        let (rebuilt, writeBack) = sidecar.applyingPush(
            text: "one\n\nTWO\n",
            slices: sliced("one\n\nTWO\n"),
            putEcho: [],
            postEchoByInsert: [:],
            deletesConfirmed: true)

        XCTAssertEqual(rebuilt, sidecar)
        XCTAssertTrue(writeBack.isEmpty)
        // Still diffs as an update next round.
        XCTAssertEqual(rebuilt.pushPlan(for: sliced("one\n\nTWO\n")).updates.map(\.id),
                       ["block-1"])
    }

    func testPostEchoBecomesOrderedEntries() {
        let (rebuilt, writeBack) = BlockSidecar().applyingPush(
            text: "one\n\ntwo\n",
            slices: sliced("one\n\ntwo\n"),
            putEcho: [],
            postEchoByInsert: [
                        0: [CraftBlock(id: "n1", markdown: "one")],
                        1: [CraftBlock(id: "n2", markdown: "two")]
                       ],
            deletesConfirmed: true)

        XCTAssertEqual(rebuilt.entries.map(\.id), ["n1", "n2"])
        XCTAssertTrue(writeBack.isEmpty)
        XCTAssertTrue(rebuilt.pushPlan(for: sliced("one\n\ntwo\n")).isEmpty)
    }

    func testSplitEchoStaysInsideItsGroup() {
        let (rebuilt, _) = BlockSidecar().applyingPush(
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
        let (rebuilt, writeBack) = sidecar.applyingPush(
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
        XCTAssertEqual(writeBack.count, 1, "only the split insert writes back")
    }

    func testTightListRejoinsWithoutInjectedBlanks() {
        // Same-anchor batch of two list items, echo identical. The run
        // rejoins with the pad's own single newlines — not "\n\n" — so an
        // unchanged push writes back nothing at all.
        let (rebuilt, writeBack) = BlockSidecar().applyingPush(
            text: "- a\n- b\n",
            slices: sliced("- a\n- b\n"),
            putEcho: [],
            postEchoByInsert: [
                        0: [CraftBlock(id: "na", markdown: "- a")],
                        1: [CraftBlock(id: "nb", markdown: "- b")]
                       ],
            deletesConfirmed: true)

        XCTAssertEqual(rebuilt.entries.map(\.id), ["na", "nb"])
        XCTAssertTrue(writeBack.isEmpty)
    }

    func testFailedPostLeavesInsertsAbsent() {
        let (rebuilt, writeBack) = BlockSidecar().applyingPush(
            text: "one\n",
            slices: sliced("one\n"),
            putEcho: [],
            postEchoByInsert: [:],
            deletesConfirmed: true)

        XCTAssertTrue(rebuilt.entries.isEmpty)
        XCTAssertTrue(writeBack.isEmpty)
        XCTAssertEqual(rebuilt.pushPlan(for: sliced("one\n")).inserts.map(\.markdown),
                       ["one"])
    }

    func testSplitEchoWritesBackTheWholeRunNotOneSlice() {
        // [AAA, B] splits server-side into [a1, a2, b1]. Boundaries are
        // unknowable, so the write-back spans the run: values and order
        // exact, no slice overwritten with another's tail.
        let (rebuilt, writeBack) = BlockSidecar().applyingPush(
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
        XCTAssertEqual(writeBack.count, 1)
        XCTAssertEqual(writeBack[0].prior, "AAA\n\nB")
        XCTAssertEqual(writeBack[0].markdown, "a1\n\na2\n\nb1")

        // Convergence: folding the write-back back in re-splits 1:1 against
        // the recorded entries, so the next round is silent. A split can
        // churn ids once, never miswire them.
        let converged = "a1\n\na2\n\nb1\n"
        XCTAssertTrue(rebuilt.pushPlan(for: CraftBlockSplitter.slices(in: converged)).isEmpty)
    }

    func testConfirmedDeleteDropsEntries() {
        let sidecar = seeded(["one", "two"])
        let (rebuilt, _) = sidecar.applyingPush(
            text: "two\n",
            slices: sliced("two\n"),
            putEcho: [],
            postEchoByInsert: [:],
            deletesConfirmed: true)
        XCTAssertEqual(rebuilt.entries.map(\.id), ["block-1"])
    }

    func testUnconfirmedDeleteRestoresEntries() {
        let sidecar = seeded(["one", "two"])
        let (rebuilt, _) = sidecar.applyingPush(
            text: "two\n",
            slices: sliced("two\n"),
            putEcho: [],
            postEchoByInsert: [:],
            deletesConfirmed: false)
        XCTAssertEqual(Set(rebuilt.entries.map(\.id)), ["block-0", "block-1"],
                       "order may shift on restore; the next diff absorbs it as churn")
        // And the retry drops it exactly.
        let (retried, _) = rebuilt.applyingPush(
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
        let (rebuilt, writeBack) = sidecar.applyingPush(
            text: "one\n",
            slices: sliced("one\n"),
            putEcho: [],
            postEchoByInsert: [:],
            deletesConfirmed: true)
        XCTAssertTrue(rebuilt.entries.contains(where: { $0.id == "b" }),
                      "a pinned block is never deleted, whatever the request said")
        XCTAssertTrue(writeBack.isEmpty)
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

    func testFlushPutsTheEditStoresTheEchoAndWritesBack() async throws {
        let name = "ccp.push.flush.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"blocks":[{"id":"block-1","markdown":"TWO!"}]}
            """)])
        let adapter = adapter(store, transport)
        let id = try seed(adapter, text: "one\n\ntwo\n")

        adapter.text = "one\n\nTWO\n"
        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 1, "one PUT, nothing else")
        XCTAssertEqual(adapter.sidecar(for: id).entries[1].fingerprint,
                       BlockSidecar.fingerprint("TWO!"))
        XCTAssertEqual(adapter.text, "one\n\nTWO!\n",
                       "the canonical spelling comes back into the pad")
    }

    func testWriteBackFlagOffLeavesThePadAlone() async throws {
        let name = "ccp.push.flagoff.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        store.set(false, forKey: "scratchpadCraftWriteBack")
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"blocks":[{"id":"block-1","markdown":"TWO!"}]}
            """)])
        let adapter = adapter(store, transport)
        let id = try seed(adapter, text: "one\n\ntwo\n")

        adapter.text = "one\n\nTWO\n"
        await adapter.flushCraftPush()

        XCTAssertEqual(adapter.text, "one\n\nTWO\n")
        XCTAssertEqual(adapter.sidecar(for: id).entries[1].fingerprint,
                       BlockSidecar.fingerprint("TWO!"),
                       "the sidecar still learns the canonical form")
    }

    func testMidFlightTypingWinsOverTheEcho() async throws {
        let name = "ccp.push.midflight.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"blocks":[{"id":"block-1","markdown":"TWO!"}]}
            """)])
        let adapter = adapter(store, transport)
        _ = try seed(adapter, text: "one\n\ntwo\n")

        adapter.text = "one\n\nTWO\n"
        transport.onRequest = {
            // The user retyped the pushed block while the PUT was away.
            await MainActor.run { adapter.text = "one\n\nTW0\n" }
        }
        await adapter.flushCraftPush()

        XCTAssertEqual(adapter.text, "one\n\nTW0\n",
                       "the guard range no longer matches, so no write-back lands")
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

    func testNoMappingMeansNoRequests() async throws {
        let name = "ccp.push.nomap.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([])
        let adapter = adapter(store, transport)

        adapter.text = "unmapped words"
        await adapter.flushCraftPush()

        XCTAssertTrue(transport.requests.isEmpty,
                      "a pad with no document has nowhere to push")
    }

    func testPartialFailureStoresConfirmedUnits() async throws {
        let name = "ccp.push.partial.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        // PUT ok, DELETE 500s. Then everything ok.
        let transport = ScriptedTransport([
            .init(statusCode: 200, json: """
                {"blocks":[{"id":"block-1","markdown":"TWO!"}]}
                """),
            .init(statusCode: 500, json: "{}"),
            .init(statusCode: 200, json: """
                {"blocks":[{"id":"block-1","markdown":"TWO!"}]}
                """),
            .init(statusCode: 200, json: "{}"),
        ])
        store.set(false, forKey: "scratchpadCraftWriteBack")
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
                {"blocks":[{"id":"block-0","markdown":"A"}]}
                """),
            .init(statusCode: 200, json: """
                {"blocks":[{"id":"nx","markdown":"x"}]}
                """),
            .init(statusCode: 200, json: """
                {"blocks":[{"id":"ny","markdown":"y"}]}
                """),
        ])
        store.set(false, forKey: "scratchpadCraftWriteBack")
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

    func testPrependStallsAloneWhileAnchoredInsertsProceed() async throws {
        let name = "ccp.push.prepend.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"blocks":[{"id":"nc","markdown":"c"}]}
            """)])
        let adapter = adapter(store, transport)
        let id = try seed(adapter, text: "B\n")

        // A has no anchor (prepend, spelling unconfirmed) but c anchors to B.
        adapter.text = "A\n\nB\n\nc\n"
        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 1, "only the anchored group posts")
        XCTAssertEqual(adapter.sidecar(for: id).entries.map(\.id), ["block-0", "nc"],
                       "the prepend stays absent and retries; nothing misorders")
        XCTAssertTrue(adapter.isPushDirty(id), "a stalled pad stays dirty for later rounds")
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
            return ScriptedTransport.Script(statusCode: 200, json: "{\"blocks\":[\(echo)]}")
        }
        store.set(false, forKey: "scratchpadCraftWriteBack")
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

    func testBackgroundPadWriteBackSkipsTheBinding() async throws {
        let name = "ccp.push.background.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
            {"blocks":[{"id":"a0","markdown":"AAA!"}]}
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
        XCTAssertEqual(adapter.notes.first(where: { $0.id == first })?.text, "AAA!",
                       "the background pad learns the canonical spelling in its document")
        XCTAssertEqual(adapter.sidecar(for: first).entries.map(\.fingerprint),
                       [BlockSidecar.fingerprint("AAA!")])
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
