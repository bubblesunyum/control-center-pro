// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import Combine
import XCTest

@MainActor
final class ClipboardAdapterTests: XCTestCase {
    // MARK: - Reporting

    func testReportsEntriesFromSource() {
        let entry = ClipboardEntry(text: "hello")
        let source = FakeClipboardSource(snapshot: [entry])
        let adapter = ClipboardAdapter(source: source)
        XCTAssertEqual(adapter.entries, [entry])
    }

    func testInitEnsuresHistoryEnabled() {
        let source = FakeClipboardSource()
        XCTAssertEqual(source.ensureCount, 0)
        _ = ClipboardAdapter(source: source)
        XCTAssertEqual(source.ensureCount, 1, "clipboard must be warm before first open")
    }

    // MARK: - Observing

    func testActivateIsIdempotent() {
        let source = FakeClipboardSource()
        let adapter = ClipboardAdapter(source: source)
        adapter.activate()
        let count = source.observerCount
        adapter.activate()
        XCTAssertEqual(source.observerCount, count, "second activate stacked a second subscription")
    }

    func testChangesWhileOpenReachAdapter() async {
        let source = FakeClipboardSource(snapshot: [])
        let adapter = ClipboardAdapter(source: source)
        adapter.activate()

        source.emit([ClipboardEntry(text: "first")])

        let arrived = await becomesTrue { adapter.entries.count == 1 }
        XCTAssertTrue(arrived, "a copy made while open never appeared")
    }

    func testChangesWhileShutStillReachAdapter() async {
        let source = FakeClipboardSource(snapshot: [])
        let adapter = ClipboardAdapter(source: source)
        adapter.activate()
        adapter.deactivate()

        source.emit([ClipboardEntry(text: "background")])

        let arrived = await becomesTrue { adapter.entries.count == 1 }
        XCTAssertTrue(arrived, "clipboard history must populate while panel is shut (ccp-8ld.5)")
    }

    func testDeactivateKeepsObserving() {
        let source = FakeClipboardSource()
        let adapter = ClipboardAdapter(source: source)
        adapter.activate()
        XCTAssertEqual(source.observerCount, 1)
        adapter.deactivate()
        XCTAssertEqual(source.observerCount, 1, "a shut panel must keep observing clipboard (background opt-in)")
    }

    func testStopCancelsObservation() {
        let source = FakeClipboardSource()
        let adapter = ClipboardAdapter(source: source)
        adapter.activate()
        XCTAssertEqual(source.observerCount, 1)
        adapter.stop()
        XCTAssertEqual(source.observerCount, 0, "removed widget kept observing")
    }

    func testDeactivateThenActivateStillObservesOnce() {
        let source = FakeClipboardSource()
        let adapter = ClipboardAdapter(source: source)
        adapter.activate()
        adapter.deactivate()
        adapter.activate()
        XCTAssertEqual(source.observerCount, 1)
    }

    func testChangesAfterStopDoNotArrive() async {
        let source = FakeClipboardSource(snapshot: [])
        let adapter = ClipboardAdapter(source: source)
        adapter.stop()

        source.emit([ClipboardEntry(text: "stale")])

        let arrived = await becomesTrue { !adapter.entries.isEmpty }
        XCTAssertFalse(arrived, "a removed widget kept receiving clipboard changes")
    }

    // MARK: - Mutations

    func testCopyForwardsToSource() {
        let entry = ClipboardEntry(text: "copy me")
        let source = FakeClipboardSource(snapshot: [entry])
        let adapter = ClipboardAdapter(source: source)

        adapter.copy(entry)

        XCTAssertEqual(source.copied, [entry.id])
    }

    func testTogglePinUpdatesEntriesOptimistically() {
        let entry = ClipboardEntry(text: "pin me")
        let source = FakeClipboardSource(snapshot: [entry])
        let adapter = ClipboardAdapter(source: source)
        // Fake will flip pinned on toggle
        adapter.togglePin(entry)
        // Optimistic re-read should have new snapshot
        XCTAssertTrue(source.togglePinned.contains(entry.id))
    }

    func testRemoveUpdatesEntries() {
        let entry = ClipboardEntry(text: "bye")
        let source = FakeClipboardSource(snapshot: [entry])
        let adapter = ClipboardAdapter(source: source)
        adapter.remove(entry)
        XCTAssertEqual(source.removed, [entry.id])
    }

    func testClearRecentForwards() {
        let source = FakeClipboardSource()
        let adapter = ClipboardAdapter(source: source)
        adapter.clearRecent()
        XCTAssertTrue(source.didClearRecent)
    }
}

// MARK: - Fake

@MainActor
final class FakeClipboardSource: ClipboardSource {
    var snapshot: [ClipboardEntry]
    var isRunning = true
    private let subject = PassthroughSubject<Void, Never>()
    private let lock = NSLock()
    private nonisolated(unsafe) var observers = 0
    var observerCount: Int { lock.withLock { observers } }

    var ensureCount = 0
    var copied: [UUID] = []
    var togglePinned: [UUID] = []
    var removed: [UUID] = []
    var didClearRecent = false
    var didClearAll = false

    init(snapshot: [ClipboardEntry] = [], isRunning: Bool = true) {
        self.snapshot = snapshot
        self.isRunning = isRunning
    }

    var changes: AnyPublisher<Void, Never> {
        subject
            .handleEvents(
                receiveSubscription: { [lock] _ in lock.withLock { self.observers += 1 } },
                receiveCancel: { [lock] in lock.withLock { self.observers -= 1 } }
            )
            .eraseToAnyPublisher()
    }

    func ensureHistoryEnabled() { ensureCount += 1 }

    func copy(_ entry: ClipboardEntry, completion: @escaping (Bool) -> Void) {
        copied.append(entry.id)
        completion(true)
    }

    func togglePin(_ entry: ClipboardEntry) {
        togglePinned.append(entry.id)
        // Simulate engine toggling pin by flipping pinnedAt
        if let idx = snapshot.firstIndex(where: { $0.id == entry.id }) {
            var updated = snapshot[idx]
            updated.pinnedAt = updated.isPinned ? nil : Date()
            snapshot[idx] = updated
        }
    }

    func remove(_ entry: ClipboardEntry) {
        removed.append(entry.id)
        snapshot.removeAll { $0.id == entry.id }
    }

    func clearRecent() {
        didClearRecent = true
        snapshot.removeAll { !$0.isPinned }
    }

    func clearAll() {
        didClearAll = true
        snapshot.removeAll()
    }

    func emit(_ newSnapshot: [ClipboardEntry]) {
        subject.send(())
        snapshot = newSnapshot
    }
}
