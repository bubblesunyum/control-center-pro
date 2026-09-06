// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import XCTest

@MainActor
final class StickyStoreTests: XCTestCase {
    private func store() -> StickyStore {
        StickyStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    func testANewStickyLandsOnTop() {
        let store = store()
        let first = store.add()
        let second = store.add()

        XCTAssertEqual(store.visible.map(\.id), [first.id, second.id])
    }

    func testMovingKeepsDrawOrder() {
        let store = store()
        let first = store.add()
        _ = store.add()

        store.move(first.id, toX: 300, toY: 400)

        // Depth is array order and never re-sorts: the moved sticky stays
        // below, where it was created.
        XCTAssertEqual(store.visible.map(\.id).first, first.id)
        XCTAssertEqual(store.visible.first?.x, 300)
        XCTAssertEqual(store.visible.first?.y, 400)
    }

    func testArchiveHidesAndUnarchiveRestores() {
        let store = store()
        let sticky = store.add()
        store.setText("keep me", for: sticky.id)

        store.archive(sticky.id)
        XCTAssertTrue(store.visible.isEmpty)
        XCTAssertEqual(store.archived.map(\.id), [sticky.id])

        store.unarchive(sticky.id)
        XCTAssertEqual(store.visible.map(\.id), [sticky.id])
        XCTAssertTrue(store.archived.isEmpty)
    }

    func testDeleteRemoves() {
        let store = store()
        let sticky = store.add()

        store.delete(sticky.id)

        XCTAssertTrue(store.visible.isEmpty)
    }

    func testUnknownIDsAreIgnored() {
        let store = store()
        _ = store.add()
        let unknown = UUID()

        store.move(unknown, toX: 1, toY: 1)
        store.setText("x", for: unknown)
        store.setColor(.pink, for: unknown)
        store.delete(unknown)
        store.archive(unknown)
        store.unarchive(unknown)

        XCTAssertEqual(store.visible.count, 1)
    }

    func testFlushRoundTripsThroughDisk() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = StickyStore(directory: directory)
        let sticky = first.add(x: 12, y: 34)
        first.setText("# hello", for: sticky.id)
        first.setColor(.blue, for: sticky.id)
        first.flush()

        let second = StickyStore(directory: directory)

        XCTAssertEqual(second.visible, first.visible)
    }

    func testOneBadStickyDoesNotCostTheFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let good = Sticky(text: "survivor", x: 1, y: 2)
        let payload = """
        [{"id":"\(good.id.uuidString)","text":"survivor","color":"yellow","x":1,"y":2,"isArchived":false},
         {"id":"not-a-uuid","text":{}}]
        """
        try Data(payload.utf8).write(to: directory.appendingPathComponent("stickies.json"))

        let store = StickyStore(directory: directory)

        XCTAssertEqual(store.visible, [good])
    }

    func testStickiesWrittenBeforeArchiveDecodesVisible() throws {
        let legacy = """
        {"id":"6C1D6C4E-7C6E-4B1E-9E8B-2D9A1C0F5B31","text":"old","color":"pink","x":3,"y":4}
        """
        let sticky = try JSONDecoder().decode(Sticky.self, from: Data(legacy.utf8))

        XCTAssertFalse(sticky.isArchived)
        XCTAssertEqual(sticky.color, .pink)
    }

    func testAFileWithNothingSalvageableIsMovedAside() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: directory.appendingPathComponent("stickies.json"))

        let store = StickyStore(directory: directory)

        // Empty desk, but the evidence survives for whoever asks why.
        XCTAssertTrue(store.visible.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("stickies.json.corrupt").path
        ))
    }

    func testDisplayTitleFallsBackWhenEmpty() {
        XCTAssertEqual(Sticky().displayTitle, "New Sticky")
        XCTAssertEqual(Sticky(text: "  \n  ").displayTitle, "New Sticky")
        XCTAssertEqual(Sticky(text: "groceries\nmilk\neggs").displayTitle, "groceries")
        XCTAssertEqual(Sticky(text: "# headed\nbody").displayTitle, "headed")
    }
}
