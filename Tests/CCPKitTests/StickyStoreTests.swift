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

        store.move(first.id, toTrailingX: 300, toY: 400)

        // Depth is array order and never re-sorts: the moved sticky stays
        // below, where it was created.
        XCTAssertEqual(store.visible.map(\.id).first, first.id)
        XCTAssertEqual(store.visible.first?.trailingX, 300)
        XCTAssertEqual(store.visible.first?.y, 400)
    }

    func testResizeStoresSizeAndKeepsDrawOrder() {
        let store = store()
        let first = store.add()
        _ = store.add()

        store.resize(first.id, width: 320, height: 240)

        XCTAssertEqual(store.visible.map(\.id).first, first.id)
        XCTAssertEqual(store.visible.first?.width, 320)
        XCTAssertEqual(store.visible.first?.height, 240)
    }

    func testResizeClampsToTheSmallestUsableNote() {
        let store = store()
        let sticky = store.add()

        store.resize(sticky.id, width: 10, height: 10)

        XCTAssertEqual(store.visible.first?.width, Sticky.minWidth)
        XCTAssertEqual(store.visible.first?.height, Sticky.minHeight)
    }

    func testResizeRoundTripsThroughDisk() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = StickyStore(directory: directory)
        let sticky = first.add(trailingX: 12, y: 34)
        first.resize(sticky.id, width: 320, height: 240)
        first.flush()

        let second = StickyStore(directory: directory)

        XCTAssertEqual(second.visible, first.visible)
        XCTAssertEqual(second.visible.first?.width, 320)
        XCTAssertEqual(second.visible.first?.height, 240)
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

        store.move(unknown, toTrailingX: 1, toY: 1)
        store.resize(unknown, width: 300, height: 300)
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
        let sticky = first.add(trailingX: 12, y: 34)
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
        let good = Sticky(text: "survivor", trailingX: 1, y: 2)
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

    func testStickiesWrittenBeforeResizeDecodeAtDefaultSize() throws {
        let legacy = """
        {"id":"6C1D6C4E-7C6E-4B1E-9E8B-2D9A1C0F5B31","text":"old","color":"pink","x":3,"y":4,"isArchived":false}
        """
        let sticky = try JSONDecoder().decode(Sticky.self, from: Data(legacy.utf8))

        XCTAssertEqual(sticky.width, Sticky.defaultWidth)
        XCTAssertEqual(sticky.height, Sticky.defaultHeight)
    }

    func testMistypedSizeFallsBackInsteadOfCostingTheNote() throws {
        // A hand edit quoting the size must not read as a dead note — the
        // tolerant load would drop the item and the next flush erase it.
        let mangled = """
        {"id":"6C1D6C4E-7C6E-4B1E-9E8B-2D9A1C0F5B31","text":"keep","width":"240","height":null}
        """
        let sticky = try JSONDecoder().decode(Sticky.self, from: Data(mangled.utf8))

        XCTAssertEqual(sticky.text, "keep")
        XCTAssertEqual(sticky.width, Sticky.defaultWidth)
        XCTAssertEqual(sticky.height, Sticky.defaultHeight)
    }

    func testAbsurdSizeLoadsClampedToTheMinimum() throws {
        let mangled = """
        {"id":"6C1D6C4E-7C6E-4B1E-9E8B-2D9A1C0F5B31","text":"keep","width":0,"height":-40}
        """
        let sticky = try JSONDecoder().decode(Sticky.self, from: Data(mangled.utf8))

        XCTAssertEqual(sticky.width, Sticky.minWidth)
        XCTAssertEqual(sticky.height, Sticky.minHeight)
    }

    func testAFileWithNothingSalvageableIsSetAsideOnFlush() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: directory.appendingPathComponent("stickies.json"))

        let store = StickyStore(directory: directory)

        // Empty desk, and the live file untouched by the read.
        XCTAssertTrue(store.visible.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("stickies.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("stickies.json.corrupt").path
        ))

        store.flush()

        // The first deliberate write keeps the evidence for whoever asks why.
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("stickies.json.corrupt"), encoding: .utf8),
            "not json at all"
        )
    }

    func testMoveByAppliesLeadingSpaceTravelToTheTrailingOffset() {
        let store = store()
        let note = store.add(trailingX: 800, y: 600)

        store.moveBy(note.id, dx: 100, dy: 50)

        // Rightward travel shrinks the trailing offset; downward grows y.
        XCTAssertEqual(store.visible.first?.trailingX, 700)
        XCTAssertEqual(store.visible.first?.y, 650)
    }

    func testMigrateToTrailingAnchoringConvertsLeadingValuesInOrder() {
        let store = store()
        // Pre-migration bytes: each number is a distance from the leading
        // edge under the same `"x"` key — the conversion re-reads them.
        let first = Sticky(trailingX: 200, y: 100)
        let second = Sticky(trailingX: 900, y: 700)
        store.setStickiesForTesting([first, second])

        XCTAssertTrue(store.migrateToTrailingAnchoring(inWidth: 1000))

        XCTAssertEqual(store.visible.map(\.id), [first.id, second.id])
        XCTAssertEqual(store.visible.map(\.trailingX), [800, 100])
        XCTAssertEqual(store.visible.map(\.y), [100, 700])
    }

    func testMigrateToTrailingAnchoringIncludesArchivedNotes() {
        let store = store()
        let note = store.add(trailingX: 200, y: 100)
        store.archive(note.id)

        XCTAssertTrue(store.migrateToTrailingAnchoring(inWidth: 1000))

        store.unarchive(note.id)
        XCTAssertEqual(store.visible.first?.trailingX, 800)
    }

    func testMigrateToTrailingAnchoringRefusesZeroWidth() {
        let store = store()
        _ = store.add(trailingX: 200, y: 100)

        XCTAssertFalse(store.migrateToTrailingAnchoring(inWidth: 0))

        XCTAssertEqual(store.visible.first?.trailingX, 200)
    }

    func testDisplayTitleFallsBackWhenEmpty() {
        XCTAssertEqual(Sticky().displayTitle, "New Sticky")
        XCTAssertEqual(Sticky(text: "  \n  ").displayTitle, "New Sticky")
        XCTAssertEqual(Sticky(text: "groceries\nmilk\neggs").displayTitle, "groceries")
        XCTAssertEqual(Sticky(text: "# headed\nbody").displayTitle, "headed")
    }

    func testAddFallsBackWhenCoordinatesAreNonFinite() {
        let store = store()

        for bad in [Double.nan, .infinity, -.infinity] {
            let sticky = store.add(trailingX: bad, y: bad)

            XCTAssertEqual(sticky.trailingX, 0, "trailingX \(bad)")
            XCTAssertEqual(sticky.y, 0, "y \(bad)")
        }
    }

    func testMoveFallsBackWhenCoordinatesAreNonFinite() {
        let store = store()
        let sticky = store.add(trailingX: 100, y: 100)

        for bad in [Double.nan, .infinity, -.infinity] {
            store.move(sticky.id, toTrailingX: bad, toY: bad)

            XCTAssertEqual(store.visible.first?.trailingX, 0, "trailingX \(bad)")
            XCTAssertEqual(store.visible.first?.y, 0, "y \(bad)")

            store.move(sticky.id, toTrailingX: 100, toY: 100)
        }
    }

    func testMoveByHealsNonFiniteTravel() {
        let store = store()
        let note = store.add(trailingX: 800, y: 600)

        // A NaN drag delta poisons the axis it touches; the other axis
        // keeps its travel.
        store.moveBy(note.id, dx: .nan, dy: 50)
        XCTAssertEqual(store.visible.first?.trailingX, 0)
        XCTAssertEqual(store.visible.first?.y, 650)

        store.move(note.id, toTrailingX: 800, toY: 600)
        store.moveBy(note.id, dx: 100, dy: .infinity)
        XCTAssertEqual(store.visible.first?.trailingX, 700)
        XCTAssertEqual(store.visible.first?.y, 0)

        // Infinite travel off either edge still commits finite geometry.
        store.move(note.id, toTrailingX: 800, toY: 600)
        store.moveBy(note.id, dx: -.infinity, dy: -.infinity)
        XCTAssertEqual(store.visible.first?.trailingX, 0)
        XCTAssertEqual(store.visible.first?.y, 0)
    }

    func testResizeFallsBackToMinimumWhenSizeIsNonFinite() {
        let store = store()
        let sticky = store.add()

        for bad in [Double.nan, .infinity, -.infinity, -10] {
            store.resize(sticky.id, width: bad, height: bad)

            XCTAssertEqual(store.visible.first?.width, Sticky.minWidth, "width \(bad)")
            XCTAssertEqual(store.visible.first?.height, Sticky.minHeight, "height \(bad)")
        }
    }

    func testMigrationHealsNonFiniteTrailingOffsets() {
        // A value poisoned before the commit guards existed still converts
        // to something finite instead of surviving another generation.
        var sticky = Sticky(trailingX: 200, y: 100)
        sticky.trailingX = .nan

        sticky.convertToTrailingAnchoring(inWidth: 1000)

        XCTAssertEqual(sticky.trailingX, 0)
    }

    func testFiniteAbsurdCoordinatesPassThroughTheStoreUntouched() {
        // The store never knows the seat width, so finite values — however
        // absurd — are reclaim's and the draw clamp's to tame, not the
        // commit's to rewrite. Only non-finite geometry falls back.
        let store = store()
        let sticky = store.add(trailingX: 1e308, y: -1e308)
        store.resize(sticky.id, width: 1e308, height: 240)

        XCTAssertEqual(store.visible.first?.trailingX, 1e308)
        XCTAssertEqual(store.visible.first?.y, -1e308)
        XCTAssertEqual(store.visible.first?.width, 1e308)
        XCTAssertEqual(store.visible.first?.height, 240)
    }
}
