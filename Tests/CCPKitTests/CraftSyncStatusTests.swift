// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

/// The toolbar tells waiting apart from failed (ccp-2zi.7): dirty pads read
/// pending until a push actually fails, failed once it has, and a proving
/// pull still outranks both. Reuses the push file's scripted transport.
@MainActor
final class CraftSyncStatusTests: XCTestCase {
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

    /// A mapped pad holding `text`, converged and clean.
    @discardableResult
    private func steadyPad(_ adapter: NotesAdapter, _ destination: CraftNoteDestination,
                           text: String) async throws -> UUID {
        let id = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = text
        destination.storeBase(.fixture(text, blocks: [text]), for: id)
        destination.setCraftDocumentID("doc1", for: id)
        destination.storeSyncedTitle(adapter.selectedNoteName, for: id)
        await adapter.flushCraftPush()
        XCTAssertFalse(adapter.isPushDirty(id), "steady state starts clean")
        return id
    }

    private func trash(_ ids: String...) -> ScriptedTransport.Script {
        let items = ids.map { "{\"id\":\"\($0)\"}" }.joined(separator: ",")
        return ScriptedTransport.Script(statusCode: 200, json: "{\"items\":[\(items)]}")
    }

    /// A verified pad with unpushed edits and no failure reads pending —
    /// the debounce window, not a problem.
    func testDirtyWithoutFailureReadsPending() async throws {
        let name = "ccp.status.pending.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash()])
        transport.documentBlocks = [("block-0", "one")]
        let (adapter, destination) = adapter(store, transport)
        let id = try await steadyPad(adapter, destination, text: "one")

        await adapter.pullAll()
        XCTAssertEqual(adapter.syncStatus, .saved)

        adapter.text = "one edited"

        XCTAssertTrue(adapter.isPushDirty(id))
        XCTAssertFalse(adapter.isPushFailed(id))
        XCTAssertEqual(adapter.syncStatus, .unsavedChanges)
    }

    /// A failed push reads failed with its reason, keeps the dirty bit, and
    /// a healing retry clears back to saved.
    func testFailedPushReadsFailedAndHealsOnRetry() async throws {
        let name = "ccp.status.failed.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash()])
        transport.documentBlocks = [("block-0", "one")]
        let (adapter, destination) = adapter(store, transport)
        let id = try await steadyPad(adapter, destination, text: "one")
        await adapter.pullAll()
        XCTAssertEqual(adapter.syncStatus, .saved)

        adapter.text = "one edited"
        // Scripts spent: every request now answers 500, starting with the
        // trash sweep — the round backs off with the dirty bit standing.
        await adapter.flushCraftPush()

        XCTAssertTrue(adapter.isPushDirty(id), "a failed round keeps the intent")
        XCTAssertTrue(adapter.isPushFailed(id))
        XCTAssertEqual(adapter.lastPushErrorDescription, "Craft unreachable")
        XCTAssertEqual(adapter.syncStatus, .failed)

        transport.documentBlocks = [("block-0", "one edited")]
        transport.respond = { request in
            if request.httpMethod == "GET",
               (request.url?.query ?? "").contains("location=trash") {
                return .init(statusCode: 200, json: "{\"items\":[]}")
            }
            return .init(statusCode: 200, json: """
                {"items":[{"id":"block-0","markdown":"one edited"}]}
                """)
        }
        await adapter.flushCraftPush()

        XCTAssertFalse(adapter.isPushDirty(id))
        XCTAssertFalse(adapter.isPushFailed(id))
        XCTAssertNil(adapter.lastPushErrorDescription)
        XCTAssertEqual(adapter.syncStatus, .saved)
    }

    /// A pull that never proves outranks a failed push: the pad reads
    /// offline, not failed — reachability is the open question, not the push.
    func testPullFailureOutranksPushFailure() async throws {
        let name = "ccp.status.offline.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash()])
        transport.documentBlocks = [("block-0", "one")]
        let (adapter, destination) = adapter(store, transport)
        _ = try await steadyPad(adapter, destination, text: "one")
        await adapter.pullAll()

        adapter.text = "one edited"
        await adapter.flushCraftPush()
        XCTAssertEqual(adapter.syncStatus, .failed, "the push failed first")

        transport.respond = nil
        transport.scripts = [.init(statusCode: 500, json: "{}")]
        await adapter.pullAll()

        XCTAssertEqual(adapter.syncStatus, .offline)
    }

    /// A throttled push names its reason: rate-limited reads failed with
    /// the backoff cause, on an unmapped pad's very first provision.
    func testRateLimitedPushReadsFailedWithReason() async throws {
        let name = "ccp.status.ratelimit.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash()])
        let (adapter, _) = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)

        await adapter.pullAll()
        XCTAssertTrue(adapter.isSyncVerified)

        adapter.text = "hello"
        XCTAssertEqual(adapter.syncStatus, .unsavedChanges, "nothing failed yet")

        transport.scripts = [.init(statusCode: 429, json: "{}",
                                   headers: ["Retry-After": "45"])]
        await adapter.flushCraftPush()

        XCTAssertTrue(adapter.isPushFailed(id))
        XCTAssertEqual(adapter.lastPushErrorDescription, "Rate limited — retrying")
        XCTAssertEqual(adapter.syncStatus, .failed)
    }

    /// One pad's failure brands only that pad: a second pad typed after the
    /// failure but never attempted still reads pending.
    func testFailureIsPerPad() async throws {
        let name = "ccp.status.perpad.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash()])
        transport.documentBlocks = [("block-0", "one")]
        let (adapter, destination) = adapter(store, transport)
        let first = try await steadyPad(adapter, destination, text: "one")
        await adapter.pullAll()

        adapter.text = "one edited"
        // Scripts spent: the trash sweep 500s and the round backs off.
        await adapter.flushCraftPush()
        XCTAssertEqual(adapter.syncStatus, .failed)

        adapter.createNote()
        let second = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = "two, never attempted"

        XCTAssertTrue(adapter.isPushFailed(first))
        XCTAssertFalse(adapter.isPushFailed(second))
        XCTAssertEqual(adapter.syncStatus, .unsavedChanges,
                       "the unattempted pad reads pending, not failed")

        adapter.selectNote(first)
        XCTAssertEqual(adapter.syncStatus, .failed, "the failed pad keeps its state")
    }

    /// Deleting a failed pad drops its failure with it: the reason clears
    /// and the next edit starts pending, not failed.
    func testDeleteClearsTheFailure() async throws {
        let name = "ccp.status.delete.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash()])
        transport.documentBlocks = [("block-0", "one")]
        let (adapter, destination) = adapter(store, transport)
        let doomed = try await steadyPad(adapter, destination, text: "one")
        await adapter.pullAll()
        adapter.createNote()

        adapter.selectNote(doomed)
        adapter.text = "one edited"
        await adapter.flushCraftPush()
        XCTAssertEqual(adapter.syncStatus, .failed)

        XCTAssertTrue(adapter.deleteNote(doomed))
        XCTAssertFalse(adapter.isPushFailed(doomed))
        XCTAssertNil(adapter.lastPushErrorDescription)

        adapter.text = "two edited after the delete"
        XCTAssertEqual(adapter.syncStatus, .unsavedChanges)
    }

    /// A pad the failed round wrote clean is not failed: re-editing it
    /// starts pending, even though the round failed on its neighbour.
    func testWrittenCleanInAFailedRoundIsNotFailed() async throws {
        let name = "ccp.status.mixed.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash()])
        transport.documentBlocks = [("block-0", "a")]
        let (adapter, destination) = adapter(store, transport)
        let first = try await steadyPad(adapter, destination, text: "a")
        await adapter.pullAll()

        adapter.createNote()
        let second = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = "b"
        destination.storeBase(.fixture("b", blocks: ["b"]), for: second)
        destination.setCraftDocumentID("doc2", for: second)
        destination.storeSyncedTitle(adapter.selectedNoteName, for: second)
        await adapter.flushCraftPush()

        adapter.selectNote(first)
        adapter.text = "a edited"
        adapter.selectNote(second)
        adapter.text = "b edited"
        transport.documentBlocks = [("block-0", "b edited")]
        transport.respond = { request in
            if request.httpMethod == "GET",
               (request.url?.query ?? "").contains("location=trash") {
                return .init(statusCode: 200, json: "{\"items\":[]}")
            }
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if body.contains("a edited") {
                return .init(statusCode: 500, json: "{}")
            }
            return .init(statusCode: 200, json: """
                {"items":[{"id":"block-0","markdown":"b edited"}]}
                """)
        }
        await adapter.flushCraftPush()

        XCTAssertTrue(adapter.isPushDirty(first))
        XCTAssertTrue(adapter.isPushFailed(first))
        XCTAssertFalse(adapter.isPushDirty(second), "the neighbour wrote clean mid-failure")
        XCTAssertFalse(adapter.isPushFailed(second))

        adapter.text = "b edited again"
        XCTAssertEqual(adapter.syncStatus, .unsavedChanges,
                       "the rewritten pad retries pending, not failed")
        adapter.selectNote(first)
        XCTAssertEqual(adapter.syncStatus, .failed)
    }

    /// A blocked trash sweep fails only the pads it gated: the unmapped pad
    /// it never visited stays pending.
    func testTrashBlockedRoundFailsOnlyMappedWriters() async throws {
        let name = "ccp.status.sweep.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash()])
        transport.documentBlocks = [("block-0", "one")]
        let (adapter, destination) = adapter(store, transport)
        let mapped = try await steadyPad(adapter, destination, text: "one")
        await adapter.pullAll()

        adapter.createNote()
        let fresh = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = "unmapped words"
        adapter.selectNote(mapped)
        adapter.text = "one edited"

        // Scripts spent: the sweep 500s and the round backs off unattempted.
        await adapter.flushCraftPush()

        XCTAssertTrue(adapter.isPushFailed(mapped))
        adapter.selectNote(mapped)
        XCTAssertEqual(adapter.syncStatus, .failed)
        adapter.selectNote(fresh)
        XCTAssertFalse(adapter.isPushFailed(fresh))
        XCTAssertEqual(adapter.syncStatus, .unsavedChanges,
                       "the pad the sweep never gated stays pending")
    }

    /// Past the final backoff no retry is armed: the failure keeps its state
    /// but stops being scheduled.
    func testExhaustedBackoffSchedulesNoRetry() async throws {
        let name = "ccp.status.backoff.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, trash()])
        transport.documentBlocks = [("block-0", "one")]
        let (adapter, destination) = adapter(store, transport)
        let id = try await steadyPad(adapter, destination, text: "one")
        await adapter.pullAll()

        adapter.text = "one edited"
        transport.scripts = (0..<4).map { _ in .init(statusCode: 500, json: "{}") }

        await adapter.flushCraftPush()
        XCTAssertEqual(adapter.syncStatus, .failed)
        XCTAssertTrue(adapter.isPushRetryScheduled, "the first failure arms a retry")

        await adapter.flushCraftPush()
        await adapter.flushCraftPush()
        await adapter.flushCraftPush()
        XCTAssertTrue(adapter.isPushDirty(id))
        XCTAssertEqual(adapter.syncStatus, .failed)
        XCTAssertFalse(adapter.isPushRetryScheduled, "past the final backoff nothing is armed")
    }
}
