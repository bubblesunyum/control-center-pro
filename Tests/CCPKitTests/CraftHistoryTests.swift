// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

/// Pad history (ccp-o3k): the destination keeps a bounded newest-first ring
/// per pad, and restoring snapshots the current text first, marks dirty, and
/// flags the replacement — while a no-op restore records nothing, poking
/// the menu spends no cap, and deleting the pad drops its history.
@MainActor
final class CraftHistoryTests: XCTestCase {
    private func defaults(_ name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func adapter(text: String) -> (NotesAdapter, UUID) {
        let id = UUID()
        let adapter = NotesAdapter(document: NotesDocument(
            notes: [Note(id: id, name: "Note", text: text)], selectedID: id))
        return (adapter, id)
    }

    private func twoPads(first: String, second: String) -> (NotesAdapter, UUID, UUID) {
        let firstID = UUID()
        let secondID = UUID()
        let adapter = NotesAdapter(document: NotesDocument(
            notes: [Note(id: firstID, name: "First", text: first),
                    Note(id: secondID, name: "Second", text: second)],
            selectedID: firstID))
        return (adapter, firstID, secondID)
    }

    func testRingKeepsTenNewestFirst() throws {
        let name = "ccp.history.ring.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let destination = CraftNoteDestination(defaults: store)
        let id = UUID()
        for index in 0..<12 {
            destination.recordSnapshot(markdown: "v\(index)", reason: .pull, date: nil, for: id)
        }
        let kept = destination.snapshots(for: id)
        XCTAssertEqual(kept.count, 10)
        XCTAssertEqual(kept.map(\.markdown), (2..<12).reversed().map { "v\($0)" })
        XCTAssertTrue(kept.allSatisfy { $0.reason == .pull })
    }

    func testDropSnapshotsLeavesSyncStateAndViceVersa() throws {
        let name = "ccp.history.drop.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let destination = CraftNoteDestination(defaults: store)
        let id = UUID()
        destination.recordSnapshot(markdown: "kept", reason: .pull, date: nil, for: id)
        destination.setCraftDocumentID("doc1", for: id)
        destination.dropSnapshots(for: id)
        XCTAssertTrue(destination.snapshots(for: id).isEmpty)
        XCTAssertEqual(destination.craftDocumentID(for: id), "doc1")

        // Unmapping drops the mapping but keeps the way back: the pad
        // survives local-only, still edited.
        destination.recordSnapshot(markdown: "kept", reason: .pull, date: nil, for: id)
        destination.dropSyncState(for: id)
        XCTAssertEqual(destination.snapshots(for: id).count, 1)
        XCTAssertNil(destination.craftDocumentID(for: id))
    }

    func testRestoreSetsTextMarksDirtyAndSnapshotsCurrentFirst() throws {
        let (adapter, id) = adapter(text: "current")
        adapter.recordSnapshot(markdown: "saved", reason: .pull, date: nil, for: id)
        let savedID = try XCTUnwrap(adapter.snapshots(for: id).first?.id)

        adapter.restoreSnapshot(savedID, for: id)

        XCTAssertEqual(adapter.text, "saved")
        XCTAssertTrue(adapter.isPushDirty(id), "a restore pushes like any other edit")
        let ring = adapter.snapshots(for: id)
        XCTAssertEqual(ring.count, 2)
        XCTAssertEqual(ring[0].reason, .preRestore)
        XCTAssertEqual(ring[0].markdown, "current")
        XCTAssertEqual(adapter.padsPendingUndoClear, [id])
    }

    func testRestoreIdenticalTextRecordsNothing() throws {
        let (adapter, id) = adapter(text: "same")
        adapter.recordSnapshot(markdown: "same", reason: .pull, date: nil, for: id)
        let savedID = try XCTUnwrap(adapter.snapshots(for: id).first?.id)

        adapter.restoreSnapshot(savedID, for: id)

        XCTAssertEqual(adapter.snapshots(for: id).count, 1,
                      "no pre-restore copy of identical text")
        XCTAssertTrue(adapter.padsPendingUndoClear.isEmpty, "no replacement happened")
        XCTAssertFalse(adapter.isPushDirty(id))
    }

    func testRestoreSkipsBackupWhenCurrentIsAlreadyKept() throws {
        // Poking the menu must not spend the cap: a current text the ring
        // already holds restores back onto identical bytes.
        let (adapter, id) = adapter(text: "A")
        adapter.recordSnapshot(markdown: "B", reason: .pull, date: nil, for: id)
        adapter.recordSnapshot(markdown: "A", reason: .pull, date: nil, for: id)
        let ids = adapter.snapshots(for: id).map(\.id)

        adapter.restoreSnapshot(ids[1], for: id)
        XCTAssertEqual(adapter.text, "B")
        XCTAssertEqual(adapter.snapshots(for: id).count, 2, "no backup of an already-kept text")
        adapter.restoreSnapshot(ids[0], for: id)
        XCTAssertEqual(adapter.text, "A")
        XCTAssertEqual(adapter.snapshots(for: id).count, 2, "round-tripping spends nothing")
    }

    func testRestoreEmptyCurrentSetsTextWithoutSnapshottingEmptiness() throws {
        let (adapter, id) = adapter(text: "")
        adapter.recordSnapshot(markdown: "saved", reason: .pull, date: nil, for: id)
        let savedID = try XCTUnwrap(adapter.snapshots(for: id).first?.id)

        adapter.restoreSnapshot(savedID, for: id)

        XCTAssertEqual(adapter.text, "saved")
        XCTAssertEqual(adapter.snapshots(for: id).count, 1,
                      "emptiness is not worth a snapshot")
        XCTAssertTrue(adapter.isPushDirty(id))
        XCTAssertEqual(adapter.padsPendingUndoClear, [id], "the text was still replaced")
    }

    func testTypingNeitherSnapshotsNorFlagsReplacement() throws {
        // The undo-clear answers wholesale replacements only: keystrokes
        // must leave the stack alone, so typing records nothing and flags
        // nothing — the surface has nothing to spend.
        let (adapter, id) = adapter(text: "hello")

        adapter.text = "hello edited"

        XCTAssertTrue(adapter.snapshots(for: id).isEmpty)
        XCTAssertTrue(adapter.padsPendingUndoClear.isEmpty)
        XCTAssertTrue(adapter.isPushDirty(id), "typing still pushes as usual")
    }

    func testRestoreUnknownSnapshotIsNoOp() throws {
        let (adapter, id) = adapter(text: "current")

        adapter.restoreSnapshot(UUID(), for: id)

        XCTAssertEqual(adapter.text, "current")
        XCTAssertTrue(adapter.snapshots(for: id).isEmpty)
        XCTAssertTrue(adapter.padsPendingUndoClear.isEmpty)
        XCTAssertFalse(adapter.isPushDirty(id))
    }

    func testReplacementFlagsAccumulateAcrossPads() throws {
        // One pull adopts every mapped pad: the signal must hold both, or
        // the first pad's undo clear never fires.
        let (adapter, first, second) = twoPads(first: "one", second: "two")
        adapter.recordSnapshot(markdown: "old-one", reason: .pull, date: nil, for: first)
        adapter.recordSnapshot(markdown: "old-two", reason: .pull, date: nil, for: second)
        let firstID = try XCTUnwrap(adapter.snapshots(for: first).first?.id)
        let secondID = try XCTUnwrap(adapter.snapshots(for: second).first?.id)

        adapter.restoreSnapshot(firstID, for: first)
        adapter.restoreSnapshot(secondID, for: second)

        XCTAssertEqual(adapter.padsPendingUndoClear, [first, second])
        adapter.acknowledgeUndoClear(for: first)
        XCTAssertEqual(adapter.padsPendingUndoClear, [second])
    }

    func testDeleteDropsHistoryAndPendingFlags() throws {
        let (adapter, first, _) = twoPads(first: "one", second: "two")
        adapter.recordSnapshot(markdown: "old-one", reason: .pull, date: nil, for: first)
        let savedID = try XCTUnwrap(adapter.snapshots(for: first).first?.id)
        adapter.restoreSnapshot(savedID, for: first)
        XCTAssertEqual(adapter.padsPendingUndoClear, [first])

        XCTAssertTrue(adapter.deleteNote(first))

        XCTAssertTrue(adapter.snapshots(for: first).isEmpty, "history dies with the pad")
        XCTAssertTrue(adapter.padsPendingUndoClear.isEmpty)
    }
}
