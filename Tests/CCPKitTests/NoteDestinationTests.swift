// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

/// In-memory `CraftSyncStore`: the second implementation proving the seam is
/// real (ccp-2zi.4). The sync engine behind `any CraftSyncStore` runs
/// unchanged against it — if the fake substitutes cleanly across a push and
/// a pull, the adapter depends on the seam rather than on Craft.
final class FakeCraftSyncStore: CraftSyncStore {
    private var bases: [String: PadSyncBase] = [:]
    private var documents: [String: String] = [:]
    private var titles: [String: String] = [:]
    private var renameDates: [String: Date] = [:]
    private var syncedAts: [String: Date] = [:]
    private var stashes: [String: [String]] = [:]
    private var records: [String: [ConflictRecord]] = [:]
    private var snapshots: [String: [PadSnapshot]] = [:]
    private var spaceID: String?
    /// Mirrors CraftNoteDestination's cap: substitution must preserve it.
    private static let maximumConflictsPerPad = 5
    /// Same: the ring bound is seam behaviour, not backend choice.
    private static let maximumSnapshotsPerPad = 10

    func base(for id: UUID) -> PadSyncBase {
        bases[id.uuidString] ?? PadSyncBase()
    }

    func storeBase(_ base: PadSyncBase, for id: UUID) {
        bases[id.uuidString] = base
    }

    func dropBase(for id: UUID) {
        bases[id.uuidString] = nil
    }

    func craftDocumentID(for id: UUID) -> String? {
        documents[id.uuidString]
    }

    func setCraftDocumentID(_ docID: String, for id: UUID) {
        documents[id.uuidString] = docID
    }

    func dropCraftDocumentID(for id: UUID) {
        documents[id.uuidString] = nil
    }

    var mappedPadIDs: [UUID] {
        documents.keys.compactMap(UUID.init(uuidString:))
    }

    func syncedTitle(for id: UUID) -> String? {
        titles[id.uuidString]
    }

    func storeSyncedTitle(_ title: String?, for id: UUID) {
        titles[id.uuidString] = title
    }

    func dropSyncedTitle(for id: UUID) {
        titles[id.uuidString] = nil
    }

    func titleRenameDate(for id: UUID) -> Date? {
        renameDates[id.uuidString]
    }

    func storeTitleRenameDate(_ date: Date?, for id: UUID) {
        renameDates[id.uuidString] = date
    }

    func dropTitleRenameDate(for id: UUID) {
        renameDates[id.uuidString] = nil
    }

    func syncedAt(for id: UUID) -> Date? {
        syncedAts[id.uuidString]
    }

    func storeSyncedAt(_ date: Date?, for id: UUID) {
        guard let date else { return }
        syncedAts[id.uuidString] = date
    }

    func dropSyncedAt(for id: UUID) {
        syncedAts[id.uuidString] = nil
    }

    func stashIDs(for id: UUID) -> Set<String> {
        Set(stashes[id.uuidString] ?? [])
    }

    func storeStashIDs(_ ids: Set<String>, for id: UUID) {
        stashes[id.uuidString] = ids.isEmpty ? nil : Array(ids)
    }

    func dropStashIDs(for id: UUID) {
        stashes[id.uuidString] = nil
    }

    func conflicts(for id: UUID) -> [ConflictRecord] {
        records[id.uuidString] ?? []
    }

    func recordConflict(slices: [String], date: Date?, for id: UUID) {
        let record = ConflictRecord(date: date, slices: slices)
        records[id.uuidString] = Array(([record] + conflicts(for: id))
            .prefix(Self.maximumConflictsPerPad))
    }

    func dismissConflict(_ recordID: UUID, for id: UUID) {
        let kept = conflicts(for: id).filter { $0.id != recordID }
        records[id.uuidString] = kept.isEmpty ? nil : kept
    }

    func dropConflicts(for id: UUID) {
        records[id.uuidString] = nil
    }

    func snapshots(for id: UUID) -> [PadSnapshot] {
        snapshots[id.uuidString] ?? []
    }

    func recordSnapshot(markdown: String, reason: SnapshotReason, date: Date?, for id: UUID) {
        let snapshot = PadSnapshot(date: date, reason: reason, markdown: markdown)
        snapshots[id.uuidString] = Array(([snapshot] + snapshots(for: id))
            .prefix(Self.maximumSnapshotsPerPad))
    }

    func dropSnapshots(for id: UUID) {
        snapshots[id.uuidString] = nil
    }

    var craftSpaceID: String? { spaceID }

    func storeCraftSpaceID(_ id: String?) {
        spaceID = (id?.isEmpty == false) ? id : nil
    }

    func dropSyncState(for id: UUID) {
        dropBase(for: id)
        dropCraftDocumentID(for: id)
        dropSyncedTitle(for: id)
        dropTitleRenameDate(for: id)
        dropConflicts(for: id)
        dropStashIDs(for: id)
        dropSyncedAt(for: id)
    }
}

/// The Craft backend's own storage: every key round-trips, a relaunch reads
/// back, and dropping a pad leaves the space alone.
@MainActor
final class CraftNoteDestinationTests: XCTestCase {
    private func defaults(_ name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testEveryKeyRoundTrips() throws {
        let name = "ccp.destination.roundtrip.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let destination = CraftNoteDestination(defaults: store)
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_000_000)

        let base = PadSyncBase.fixture("one", ids: ["b1"])
        destination.storeBase(base, for: id)
        destination.setCraftDocumentID("doc-1", for: id)
        destination.storeSyncedTitle("Title", for: id)
        destination.storeTitleRenameDate(date, for: id)
        destination.storeSyncedAt(date, for: id)
        store.set(["a", "b"], forKey: "scratchpadCraftStash.\(id.uuidString)")
        destination.recordConflict(slices: ["kept"], date: date, for: id)
        destination.storeCraftSpaceID("space-1")

        XCTAssertEqual(destination.base(for: id), base)
        XCTAssertEqual(destination.craftDocumentID(for: id), "doc-1")
        XCTAssertEqual(destination.mappedPadIDs, [id])
        XCTAssertEqual(destination.syncedTitle(for: id), "Title")
        XCTAssertEqual(destination.titleRenameDate(for: id), date)
        XCTAssertEqual(destination.syncedAt(for: id), date)
        XCTAssertEqual(destination.conflicts(for: id).map(\.slices), [["kept"]])
        XCTAssertEqual(destination.conflicts(for: id).first?.date, date)
        XCTAssertEqual(destination.craftSpaceID, "space-1")
    }

    func testStateSurvivesRelaunch() throws {
        let name = "ccp.destination.relaunch.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let id = UUID()
        do {
            let first = CraftNoteDestination(defaults: store)
            first.storeBase(.fixture("one", ids: ["b1"]), for: id)
            first.setCraftDocumentID("doc-1", for: id)
            first.storeSyncedTitle("Title", for: id)
            first.recordConflict(slices: ["kept"], date: nil, for: id)
            first.storeCraftSpaceID("space-1")
        }

        let relaunched = CraftNoteDestination(defaults: store)
        XCTAssertEqual(relaunched.base(for: id).blocks.map(\.id), ["b1"])
        XCTAssertEqual(relaunched.craftDocumentID(for: id), "doc-1")
        XCTAssertEqual(relaunched.syncedTitle(for: id), "Title")
        XCTAssertEqual(relaunched.conflicts(for: id).map(\.slices), [["kept"]])
        XCTAssertEqual(relaunched.craftSpaceID, "space-1")
    }

    func testDropSyncStateClearsPadsButKeepsSpace() throws {
        let name = "ccp.destination.drop.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let destination = CraftNoteDestination(defaults: store)
        let id = UUID()
        let date = Date()
        destination.storeBase(.fixture("one", ids: ["b1"]), for: id)
        destination.setCraftDocumentID("doc-1", for: id)
        destination.storeSyncedTitle("Title", for: id)
        destination.storeTitleRenameDate(date, for: id)
        destination.storeSyncedAt(date, for: id)
        destination.recordConflict(slices: ["kept"], date: nil, for: id)
        destination.storeCraftSpaceID("space-1")

        destination.dropSyncState(for: id)

        XCTAssertTrue(destination.base(for: id).blocks.isEmpty)
        XCTAssertNil(destination.craftDocumentID(for: id))
        XCTAssertTrue(destination.mappedPadIDs.isEmpty)
        XCTAssertNil(destination.syncedTitle(for: id))
        XCTAssertNil(destination.titleRenameDate(for: id))
        XCTAssertNil(destination.syncedAt(for: id))
        XCTAssertTrue(destination.stashIDs(for: id).isEmpty)
        XCTAssertTrue(destination.conflicts(for: id).isEmpty)
        XCTAssertEqual(destination.craftSpaceID, "space-1",
                       "the space is per-space, not per-pad — dropping a pad keeps it")
    }
}

/// The seam proof: the sync engine runs end to end against the fake, through
/// `any CraftSyncStore`, with the scripted network standing in for Craft.
@MainActor
final class NoteDestinationSeamTests: XCTestCase {
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
                         destination: any CraftSyncStore, dir: URL? = nil) -> NotesAdapter {
        let adapter = NotesAdapter(defaults: store, defaultName: "Note",
                                   notesDirectory: dir ?? freshNotesDirectory(),
                                   destination: destination)
        adapter.craftTransport = transport
        adapter.craftBaseURLOverride = base
        return adapter
    }

    /// Empty trash listing, spent by the pre-write sweep in every round that
    /// pushes mapped pads.
    private func emptyTrash() -> ScriptedTransport.Script {
        .init(statusCode: 200, json: "{\"items\":[]}")
    }

    private func blocks(_ json: String) -> ScriptedTransport.Script {
        ScriptedTransport.Script(statusCode: 200, json: json)
    }

    func testPushConvergesAgainstTheFake() async throws {
        let name = "ccp.seam.push.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([emptyTrash(), .init(statusCode: 200, json: """
            {"items":[{"id":"block-1","markdown":"TWO!"}]}
            """), .init(statusCode: 200, json: """
            {"items":[{"id":"block-0","markdown":"one"},{"id":"block-1","markdown":"TWO!"}]}
            """)])
        let fake = FakeCraftSyncStore()
        let adapter = adapter(store, transport, destination: fake)
        let id = try XCTUnwrap(adapter.selectedNoteID)
        fake.storeBase(.fixture("one\n\ntwo\n"), for: id)
        fake.setCraftDocumentID("doc1", for: id)
        fake.storeSyncedTitle(adapter.selectedNoteName, for: id)

        adapter.text = "one\n\nTWO\n"
        await adapter.flushCraftPush()

        XCTAssertEqual(transport.requests.count, 3, "trash sweep, one PUT, one read-back")
        XCTAssertEqual(fake.base(for: id).blocks.map(\.markdown), ["one", "TWO!"],
                       "what Craft holds lands in the fake, through the seam")
        XCTAssertEqual(fake.craftDocumentID(for: id), "doc1")
        XCTAssertFalse(adapter.isPushDirty(id))
    }

    func testPullAdoptsAgainstTheFake() async throws {
        let name = "ccp.seam.pull.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = ScriptedTransport([connection, emptyTrash(), blocks("""
            {"items":[{"id":"block-0","markdown":"ONE"}]}
            """)])
        let fake = FakeCraftSyncStore()
        let adapter = adapter(store, transport, destination: fake)
        let id = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = "one"
        fake.storeBase(.fixture("one"), for: id)
        fake.setCraftDocumentID("doc1", for: id)
        fake.storeSyncedTitle(adapter.selectedNoteName, for: id)
        await adapter.flushCraftPush()
        XCTAssertFalse(adapter.isPushDirty(id), "steady state starts clean")

        await adapter.pullAll()

        XCTAssertEqual(transport.requests.count, 3, "clock, trash plus one fetch, no writes")
        XCTAssertEqual(adapter.text, "ONE")
        XCTAssertEqual(fake.base(for: id).blocks.map(\.id), ["block-0"])
        XCTAssertNotNil(fake.syncedAt(for: id))
        XCTAssertFalse(adapter.isPushDirty(id), "adopted text must not re-push")
    }

    func testConflictRecordsPublishThroughTheAdapter() async throws {
        let name = "ccp.seam.records.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let fake = FakeCraftSyncStore()
        let adapter = adapter(store, ScriptedTransport([]), destination: fake)
        let id = try XCTUnwrap(adapter.selectedNoteID)
        XCTAssertEqual(adapter.conflictsVersion, 0)

        adapter.recordConflict(slices: ["v1"], date: nil, for: id)
        adapter.recordConflict(slices: ["v2"], date: nil, for: id)
        XCTAssertEqual(adapter.conflictsVersion, 2, "records publish for the toolbar")
        XCTAssertEqual(adapter.conflicts(for: id).map(\.slices), [["v2"], ["v1"]])
        XCTAssertEqual(fake.conflicts(for: id).count, 2,
                       "the records live in the destination, the bump on the adapter")

        let doomed = try XCTUnwrap(adapter.conflicts(for: id).first?.id)
        adapter.dismissConflict(doomed, for: id)
        XCTAssertEqual(adapter.conflictsVersion, 3)
        XCTAssertEqual(adapter.conflicts(for: id).map(\.slices), [["v1"]])
    }
}
