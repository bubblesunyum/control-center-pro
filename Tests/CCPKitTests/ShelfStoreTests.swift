// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import XCTest

@MainActor
final class ShelfPinningTests: XCTestCase {
    private func store() -> ShelfStore {
        ShelfStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    private func note(_ title: String, pinned: Bool = false) -> ShelfItem {
        ShelfItem(kind: .text, title: title, text: title, isPinned: pinned)
    }

    func testPinnedItemsSortAheadOfTheRest() {
        let shelf = store()
        shelf.setItemsForTesting([note("a"), note("b"), note("c")])
        let b = shelf.items[1].id

        shelf.togglePin(b)

        XCTAssertEqual(shelf.items.map(\.title), ["b", "a", "c"])
    }

    /// The whole point of a pin: Clear is for the staging area, not for what
    /// the user said they were keeping.
    func testClearLeavesPinnedItemsBehind() {
        let shelf = store()
        shelf.setItemsForTesting([note("kept", pinned: true), note("a"), note("b")])

        shelf.clear()

        XCTAssertEqual(shelf.items.map(\.title), ["kept"])
        XCTAssertFalse(shelf.hasUnpinnedItems)
    }

    /// Explicitly removing a pinned item still removes it — a pin guards
    /// against the blunt action, not against being asked directly.
    func testRemovingAPinnedItemStillRemovesIt() {
        let shelf = store()
        shelf.setItemsForTesting([note("kept", pinned: true)])

        shelf.remove(shelf.items[0].id)

        XCTAssertTrue(shelf.items.isEmpty)
    }

    func testANewItemLandsBelowThePinsAndAboveEverythingElse() {
        let shelf = store()
        shelf.setItemsForTesting([note("kept", pinned: true), note("old")])

        shelf.addText("new")

        XCTAssertEqual(shelf.items.map(\.title), ["kept", "new", "old"])
    }

    func testOneBadItemDoesNotCostTheShelf() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let good = ShelfItem(kind: .text, title: "survivor", text: "survivor")
        let goodJSON = String(data: try JSONEncoder().encode(good), encoding: .utf8)!
        let payload = "[\(goodJSON),{\"id\":\"not-a-uuid\",\"kind\":\"text\",\"title\":{}}]"
        try Data(payload.utf8).write(to: directory.appendingPathComponent("shelf.json"))

        let shelf = ShelfStore(directory: directory)

        XCTAssertEqual(shelf.items.map(\.title), ["survivor"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("shelf.json.corrupt").path
        ), "a salvageable shelf must not be moved aside")
    }

    /// An array whose every item fails leaves nothing to keep: the read leaves
    /// the file alone, and the next flush sets it aside as evidence instead of
    /// overwriting it with an empty shelf.
    func testAShelfWithNothingSalvageableIsSetAsideOnFlush() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = #"[{"id":"not-a-uuid","kind":"text","title":{}}]"#
        try Data(payload.utf8).write(to: directory.appendingPathComponent("shelf.json"))

        let shelf = ShelfStore(directory: directory)

        XCTAssertTrue(shelf.items.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("shelf.json").path),
            "the read is non-destructive"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("shelf.json.corrupt").path
        ))

        shelf.flush()

        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("shelf.json.corrupt"), encoding: .utf8),
            payload
        )
    }
}

final class ShelfItemCodingTests: XCTestCase {
    /// Shelves written before pinning existed have no `isPinned` key, and one
    /// item failing to decode costs the whole file.
    func testAnItemWrittenBeforePinningDecodesUnpinned() throws {
        let legacy = """
        {"id":"6C1D6C4E-7C6E-4B1E-9E8B-2D9A1C0F5B31","kind":"text","title":"a",
         "text":"a","createdAt":0}
        """
        let item = try JSONDecoder().decode(ShelfItem.self, from: Data(legacy.utf8))

        XCTAssertEqual(item.title, "a")
        XCTAssertFalse(item.isPinned)
    }

    func testAPinSurvivesARoundTrip() throws {
        let item = ShelfItem(kind: .text, title: "a", text: "a", isPinned: true)
        let data = try JSONEncoder().encode(item)

        XCTAssertTrue(try JSONDecoder().decode(ShelfItem.self, from: data).isPinned)
    }
}
