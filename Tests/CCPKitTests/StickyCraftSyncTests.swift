// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

/// The desk half of Craft sync: the visible stickies join into one document,
/// push through the shared block engine, and pull back through the same
/// decide/merge the pads use. Driven against NormalisingCraftTransport, so
/// Craft's respelling is in the loop, not echoed away.
@MainActor
final class StickyCraftSyncTests: XCTestCase {
    private let base = URL(string: "https://connect.craft.do/links/test/api/v1")!

    private func defaults(_ name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func store(_ defaults: UserDefaults, _ transport: CraftTransport)
        -> (StickyStore, CraftNoteDestination) {
        let destination = CraftNoteDestination(defaults: defaults)
        let store = StickyStore(directory: directory(), defaults: defaults,
                                destination: destination)
        store.craftTransport = transport
        store.craftBaseURLOverride = base
        return (store, destination)
    }

    /// Two stickies pushed and converged: the steady state every pull test
    /// starts from.
    @discardableResult
    private func steadyDesk(_ store: StickyStore, _ transport: NormalisingCraftTransport,
                            first: String = "first sticky",
                            second: String = "second sticky") async -> [Sticky] {
        let one = store.add()
        let two = store.add()
        store.setText(first, for: one.id)
        store.setText(second, for: two.id)
        await store.flushCraftPush()
        return [one, two]
    }

    func testFirstPushProvisionsAndSendsSeparatorAsOwnBlock() async throws {
        let name = "ccp.sticky.provision.\(UUID().uuidString)"
        let defaults = try defaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (store, destination) = store(defaults, transport)

        await steadyDesk(store, transport)

        XCTAssertEqual(destination.craftDocumentID(for: StickyStore.craftDeskID), "doc1")
        XCTAssertEqual(transport.blocks.map(\.markdown),
                       ["first sticky", "===", "second sticky"],
                       "the separator rides as its own block, verbatim")
        XCTAssertFalse(destination.base(for: StickyStore.craftDeskID).isEmpty)
    }

    func testConvergedDeskPushesNothing() async throws {
        let name = "ccp.sticky.quiet.\(UUID().uuidString)"
        let defaults = try defaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (store, _) = store(defaults, transport)
        await steadyDesk(store, transport)

        let writes = transport.writes.count
        await store.flushCraftPush()

        XCTAssertEqual(transport.writes.count, writes, "a converged desk spends no request")
    }

    func testBlankDeskProvisionsNothing() async throws {
        let name = "ccp.sticky.empty.\(UUID().uuidString)"
        let defaults = try defaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (store, destination) = store(defaults, transport)
        store.add()

        await store.flushCraftPush()

        XCTAssertNil(destination.craftDocumentID(for: StickyStore.craftDeskID))
        XCTAssertTrue(transport.writes.isEmpty, "blank shells alone open no document")
    }

    func testPullAdoptsCraftSideSegmentKeepingShells() async throws {
        let name = "ccp.sticky.adopt.\(UUID().uuidString)"
        let defaults = try defaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (store, destination) = store(defaults, transport)
        let shells = await steadyDesk(store, transport)

        transport.blocks.append(NormalisingCraftTransport.Block(id: "craft-9", markdown: "third"))
        await store.pullAll()

        // A block Craft appends inside no separator joins the segment it
        // lands in — === is the only segment operator in either direction.
        // The trailing double-spaces are the join's hard-break glue, kept
        // verbatim by the never-re-emit rule (stripping them would read as a
        // permanent local edit and the sync would never quiet).
        XCTAssertEqual(store.visible.map(\.text), ["first sticky  ", "second sticky  \nthird"])
        XCTAssertEqual(store.visible.map(\.id), shells.map(\.id),
                       "adopt flows text through the standing shells")
        let ring = destination.snapshots(for: StickyStore.craftDeskID)
        XCTAssertEqual(ring.count, 1, "the replaced desk survives in history")
        XCTAssertEqual(ring.first?.reason, .pull)
        await store.flushCraftPush()
        XCTAssertEqual(store.syncStatus, .saved)
    }

    func testCraftSideSeparatorMintsADefaultShell() async throws {
        let name = "ccp.sticky.adopt-segment.\(UUID().uuidString)"
        let defaults = try defaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (store, _) = store(defaults, transport)
        let shells = await steadyDesk(store, transport)

        transport.blocks.append(NormalisingCraftTransport.Block(id: "craft-9", markdown: "==="))
        transport.blocks.append(NormalisingCraftTransport.Block(id: "craft-10", markdown: "third"))
        await store.pullAll()

        XCTAssertEqual(store.visible.map(\.text),
                       ["first sticky  ", "second sticky  ", "third"])
        XCTAssertEqual(store.visible.prefix(2).map(\.id), shells.map(\.id))
        XCTAssertEqual(store.visible[2].color, .yellow, "new segments mint default shells")
    }

    func testBothMovedMergesAndPushHeals() async throws {
        let name = "ccp.sticky.merge.\(UUID().uuidString)"
        let defaults = try defaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (store, _) = store(defaults, transport)
        let shells = await steadyDesk(store, transport)

        store.setText("first, edited here", for: shells[0].id)
        transport.blocks[2].markdown = "second, edited in Craft"
        await store.pullAll()

        XCTAssertEqual(store.visible.map(\.text),
                       ["first, edited here  ", "second, edited in Craft"],
                       "the merge joins with the same hard-break glue the pads keep")
        await store.flushCraftPush()
        XCTAssertEqual(transport.blocks.map(\.markdown),
                       ["first, edited here", "===", "second, edited in Craft"])
    }

    func testFailedDeleteHealsOnRetryWithoutDuplicating() async throws {
        // A half-applied round records the read-back before throwing, so the
        // retry diffs from reality instead of replaying confirmed writes.
        let name = "ccp.sticky.retry.\(UUID().uuidString)"
        let defaults = try defaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (store, _) = store(defaults, transport)
        let shells = await steadyDesk(store, transport)

        store.delete(shells[1].id)
        transport.failDelete = true
        await store.flushCraftPush()
        XCTAssertEqual(transport.blocks.map(\.markdown),
                       ["first sticky", "===", "second sticky"],
                       "the failed delete lands nowhere")

        transport.failDelete = false
        await store.flushCraftPush()
        XCTAssertEqual(transport.blocks.map(\.markdown), ["first sticky"])
        let writes = transport.writes.count
        await store.flushCraftPush()
        XCTAssertEqual(transport.writes.count, writes, "healed rounds go quiet")
    }

    func testTrashedDocumentUnmapsAndKeepsTheDesk() async throws {
        let name = "ccp.sticky.trash.\(UUID().uuidString)"
        let defaults = try defaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let connection = ScriptedTransport.Script(statusCode: 200, json: """
            {"space":{"name":"Test"},"utc":{"time":"2026-09-06T19:00:00Z"}}
            """)
        let trash = ScriptedTransport.Script(statusCode: 200, json: """
            {"items":[{"id":"doc1"}]}
            """)
        let transport = ScriptedTransport([connection, trash])
        let (store, destination) = store(defaults, transport)
        destination.setCraftDocumentID("doc1", for: StickyStore.craftDeskID)
        let one = store.add()
        store.setText("only copy anywhere", for: one.id)

        await store.pullAll()

        XCTAssertNil(destination.craftDocumentID(for: StickyStore.craftDeskID),
                     "the trashed mapping drops")
        XCTAssertEqual(store.visible.map(\.text), ["only copy anywhere"],
                       "layout and text stand, local-only")
        XCTAssertEqual(transport.requests.count, 2, "clock plus trash, no fetch, no writes")
    }

    func testArchivedStickiesStayOutOfTheDocument() async throws {
        let name = "ccp.sticky.archived.\(UUID().uuidString)"
        let defaults = try defaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (store, _) = store(defaults, transport)
        let one = store.add()
        let two = store.add()
        store.setText("on the desk", for: one.id)
        store.setText("in the drawer", for: two.id)
        store.archive(two.id)

        await store.flushCraftPush()

        XCTAssertEqual(transport.blocks.map(\.markdown), ["on the desk"])
    }
}
