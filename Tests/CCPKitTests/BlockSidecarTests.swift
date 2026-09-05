// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPKit

/// The sidecar keeps Craft's block ids stable across syncs: unchanged slices
/// produce no request at all, edits PUT in place, inserts anchor after a
/// sibling, deletes go by id — and read-only blocks are pinned whatever the
/// text around them does.
final class BlockSidecarTests: XCTestCase {
    private func slice(_ markdown: String) -> CraftBlockSlice {
        CraftBlockSlice(markdown: markdown, range: NSRange(location: 0, length: 0))
    }

    /// A sidecar as the pull side would seed it: Craft's ids over the
    /// markdowns it returned.
    private func seeded(_ markdowns: [String], isWritable: [Bool]? = nil) -> BlockSidecar {
        BlockSidecar(entries: markdowns.enumerated().map { index, markdown in
            BlockSidecarEntry(id: "block-\(index)",
                              fingerprint: BlockSidecar.fingerprint(markdown),
                              isWritable: isWritable?[index] ?? true)
        })
    }

    // MARK: Fingerprints

    func testFingerprintsAreStableAndDistinct() {
        XCTAssertEqual(BlockSidecar.fingerprint("same"), BlockSidecar.fingerprint("same"))
        XCTAssertNotEqual(BlockSidecar.fingerprint("one"), BlockSidecar.fingerprint("two"))
        // Craft's normalised form hashes where ours was taken from: the hash
        // is over whatever string it is handed, and the sidecar stores the
        // response's spelling, never the pad's.
        XCTAssertNotEqual(BlockSidecar.fingerprint("_italics_"), BlockSidecar.fingerprint("*italics*"))
    }

    // MARK: The diff

    func testUnchangedSlicesProduceNoRequests() {
        let sidecar = seeded(["one", "two"])
        XCTAssertTrue(sidecar.pushPlan(for: ["one", "two"].map(slice)).isEmpty)
    }

    func testEmptyAgainstEmptyIsEmpty() {
        XCTAssertTrue(BlockSidecar().pushPlan(for: []).isEmpty)
    }

    func testEditedBlockPutsInPlaceAndNothingElseMoves() {
        let plan = seeded(["one", "two", "three"])
            .pushPlan(for: ["one", "TWO", "three"].map(slice))
        XCTAssertEqual(plan.updates.map(\.id), ["block-1"])
        XCTAssertEqual(plan.updates.map(\.markdown), ["TWO"])
        XCTAssertTrue(plan.inserts.isEmpty)
        XCTAssertTrue(plan.deletes.isEmpty)
    }

    func testInsertedBlockAnchorsAfterItsPredecessor() {
        let plan = seeded(["one", "two"])
            .pushPlan(for: ["one", "new", "two"].map(slice))
        XCTAssertTrue(plan.updates.isEmpty)
        XCTAssertTrue(plan.deletes.isEmpty)
        XCTAssertEqual(plan.inserts.count, 1)
        XCTAssertEqual(plan.inserts[0].afterID, "block-0")
        XCTAssertEqual(plan.inserts[0].markdown, "new")
    }

    func testRemovedBlockDeletesById() {
        let plan = seeded(["one", "two", "three"])
            .pushPlan(for: ["one", "three"].map(slice))
        XCTAssertEqual(plan.deletes, ["block-1"])
        XCTAssertTrue(plan.updates.isEmpty)
        XCTAssertTrue(plan.inserts.isEmpty)
    }

    func testAppendAnchorsAfterTheLastBlock() {
        let plan = seeded(["one", "two"])
            .pushPlan(for: ["one", "two", "three"].map(slice))
        XCTAssertEqual(plan.inserts.count, 1)
        XCTAssertEqual(plan.inserts[0].afterID, "block-1")
    }

    func testPrependHasNoAnchor() {
        let plan = seeded(["one"])
            .pushPlan(for: ["zero", "one"].map(slice))
        XCTAssertEqual(plan.inserts.count, 1)
        XCTAssertNil(plan.inserts[0].afterID)
    }

    func testFirstSyncPostsEverythingInOrderWithNoAnchors() {
        let plan = BlockSidecar().pushPlan(for: ["one", "two"].map(slice))
        XCTAssertEqual(plan.inserts.map(\.markdown), ["one", "two"])
        XCTAssertTrue(plan.inserts.allSatisfy { $0.afterID == nil })
    }

    func testClearingThePadDeletesEveryBlock() {
        let plan = seeded(["one", "two"]).pushPlan(for: [])
        XCTAssertEqual(plan.deletes, ["block-0", "block-1"])
    }

    func testInsertAfterAnEditedBlockFollowsTheEditedId() {
        let plan = seeded(["one", "two", "three"])
            .pushPlan(for: ["one", "TWO", "new", "three"].map(slice))
        XCTAssertEqual(plan.updates.map(\.id), ["block-1"])
        XCTAssertEqual(plan.inserts.count, 1)
        XCTAssertEqual(plan.inserts[0].afterID, "block-1")
        XCTAssertEqual(plan.inserts[0].markdown, "new")
    }

    func testFullRewriteKeepsDocumentOrder() {
        let plan = seeded(["one", "two"]).pushPlan(for: ["x", "y", "z"].map(slice))
        XCTAssertEqual(plan.updates.map(\.id), ["block-0", "block-1"])
        XCTAssertEqual(plan.inserts.count, 1)
        XCTAssertEqual(plan.inserts[0].afterID, "block-1")
        XCTAssertEqual(plan.inserts[0].markdown, "z")
        XCTAssertTrue(plan.deletes.isEmpty)
    }

    // MARK: Read-only pinning

    func testReadOnlyBlockIsNeverUpdated() {
        let sidecar = seeded(["one", "two", "three"], isWritable: [true, false, true])
        let plan = sidecar.pushPlan(for: ["one", "TWO", "three"].map(slice))
        XCTAssertTrue(plan.isEmpty, "an edit over a read-only block is dropped, not PUT")
    }

    func testReadOnlyBlockIsNeverDeleted() {
        let sidecar = seeded(["one", "two", "three"], isWritable: [true, false, true])
        let plan = sidecar.pushPlan(for: ["one", "three"].map(slice))
        XCTAssertTrue(plan.isEmpty, "a missing read-only block pins its position, not a DELETE")
    }

    func testPushRoutesAroundPinnedBlocks() {
        let sidecar = seeded(["one", "two", "three"], isWritable: [true, false, true])
        let plan = sidecar.pushPlan(for: ["one", "TWO", "three", "four"].map(slice))
        XCTAssertTrue(plan.updates.isEmpty)
        XCTAssertTrue(plan.deletes.isEmpty)
        XCTAssertEqual(plan.inserts.count, 1)
        XCTAssertEqual(plan.inserts[0].afterID, "block-2")
        XCTAssertEqual(plan.inserts[0].markdown, "four")
    }

    // MARK: The read-only rule

    func testOutputOnlyTagsAreUnwritable() {
        XCTAssertTrue(CraftBlockPolicy.isUnwritable(markdown: "a <collection> block"))
        XCTAssertTrue(CraftBlockPolicy.isUnwritable(markdown: "<property name=\"x\">1</property>"))
        XCTAssertTrue(CraftBlockPolicy.isUnwritable(markdown: "see <itemsPreview /> here"))
        XCTAssertTrue(CraftBlockPolicy.isUnwritable(markdown: "[gone](invalid:out_of_scope)"))
    }

    func testRoundTrippableMarkupStaysWritable() {
        XCTAssertFalse(CraftBlockPolicy.isUnwritable(markdown: "plain **bold** text"))
        XCTAssertFalse(CraftBlockPolicy.isUnwritable(markdown: "a <pageTitle> nested doc"))
        XCTAssertFalse(CraftBlockPolicy.isUnwritable(markdown: "<highlight color=\"yellow\">kept</highlight>"))
        XCTAssertFalse(CraftBlockPolicy.isUnwritable(markdown: "[kept](block://abc123)"))
    }

    func testTagsInsideCodeAreLiteralTextNotBlocks() {
        XCTAssertFalse(CraftBlockPolicy.isUnwritable(
            markdown: "```html\n<title>demo</title>\n```"))
        XCTAssertFalse(CraftBlockPolicy.isUnwritable(
            markdown: "write `<title>` in the sample"))
    }

    func testUnclosedFenceErrsTowardReadOnly() {
        XCTAssertTrue(CraftBlockPolicy.isUnwritable(
            markdown: "```html\n<title>demo</title>\nand a <collection> below"))
    }

    // MARK: Persistence

    func testStoredKeysArePinned() throws {
        let entry = BlockSidecarEntry(id: "b1", fingerprint: "f", isWritable: false)
        let data = try XCTUnwrap(JSONEncoder().encode(BlockSidecar(entries: [entry])))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertEqual(Set(stored[0].keys), ["id", "fingerprint", "writable"])
        let roundTripped = try JSONDecoder().decode(BlockSidecar.self, from: data)
        XCTAssertEqual(roundTripped, BlockSidecar(entries: [entry]))
    }
}

/// The sidecar lives beside the pad in the adapter's defaults: per pad id,
/// dropped with the pad, and never written over bytes it cannot read.
@MainActor
final class BlockSidecarStorageTests: XCTestCase {
    private func defaults(_ name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func cleanup(_ name: String, _ store: UserDefaults) {
        store.removePersistentDomain(forName: name)
    }

    func testSidecarRoundTripsPerPad() throws {
        let name = "ccp.sidecar.roundtrip.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { cleanup(name, store) }
        let adapter = NotesAdapter(defaults: store, defaultName: "Note")
        let id = try XCTUnwrap(adapter.selectedNoteID)

        XCTAssertTrue(adapter.sidecar(for: id).entries.isEmpty)
        let sidecar = BlockSidecar(entries: [BlockSidecarEntry(id: "b1", fingerprint: "f")])
        adapter.storeSidecar(sidecar, for: id)
        XCTAssertEqual(adapter.sidecar(for: id), sidecar)

        let fresh = NotesAdapter(defaults: store, defaultName: "Note")
        XCTAssertEqual(fresh.sidecar(for: id), sidecar)
    }

    func testClosingANoteDropsItsSidecar() throws {
        let name = "ccp.sidecar.close.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { cleanup(name, store) }
        let adapter = NotesAdapter(defaults: store, defaultName: "Note")
        adapter.createNote()
        let doomed = adapter.notes[0].id

        adapter.storeSidecar(BlockSidecar(entries: [BlockSidecarEntry(id: "b1", fingerprint: "f")]),
                             for: doomed)
        XCTAssertTrue(adapter.closeNote(doomed))
        XCTAssertTrue(adapter.sidecar(for: doomed).entries.isEmpty)
    }

    func testUnreadableSidecarBytesReadAsNeverSynced() throws {
        let name = "ccp.sidecar.unreadable.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { cleanup(name, store) }
        let adapter = NotesAdapter(defaults: store, defaultName: "Note")
        let id = try XCTUnwrap(adapter.selectedNoteID)

        let garbage = Data("{\"not\":\"a sidecar\"}".utf8)
        store.set(garbage, forKey: "scratchpadCraftSidecars")

        XCTAssertTrue(adapter.sidecar(for: id).entries.isEmpty)
        XCTAssertEqual(store.data(forKey: "scratchpadCraftSidecars"), garbage,
                       "loading must not replace bytes it could not read")
    }

    func testHealingWriteCopiesUnreadableBytesAsideFirst() throws {
        let name = "ccp.sidecar.rescue.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { cleanup(name, store) }
        let adapter = NotesAdapter(defaults: store, defaultName: "Note")
        let id = try XCTUnwrap(adapter.selectedNoteID)

        let garbage = Data("{\"not\":\"a sidecar\"}".utf8)
        store.set(garbage, forKey: "scratchpadCraftSidecars")
        XCTAssertTrue(adapter.sidecar(for: id).entries.isEmpty)

        let sidecar = BlockSidecar(entries: [BlockSidecarEntry(id: "b1", fingerprint: "f")])
        adapter.storeSidecar(sidecar, for: id)

        XCTAssertEqual(store.data(forKey: "scratchpadCraftSidecars.unreadable"), garbage)
        XCTAssertEqual(adapter.sidecar(for: id), sidecar)
    }

    func testStoredEmptyMapDoesNotArmTheRescue() throws {
        let name = "ccp.sidecar.empty.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { cleanup(name, store) }
        let adapter = NotesAdapter(defaults: store, defaultName: "Note")
        let id = try XCTUnwrap(adapter.selectedNoteID)

        // What older builds wrote when the last entry dropped: valid JSON,
        // not corruption.
        store.set(Data("{}".utf8), forKey: "scratchpadCraftSidecars")
        XCTAssertTrue(adapter.sidecar(for: id).entries.isEmpty)

        let sidecar = BlockSidecar(entries: [BlockSidecarEntry(id: "b1", fingerprint: "f")])
        adapter.storeSidecar(sidecar, for: id)

        XCTAssertNil(store.object(forKey: "scratchpadCraftSidecars.unreadable"),
                      "no rescue copy for bytes that decoded fine")
        XCTAssertEqual(adapter.sidecar(for: id), sidecar)
    }
}
