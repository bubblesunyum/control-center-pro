// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

/// A sub-page made in Craft is another document living inside this one, and
/// the pad must treat it as a wall (ccp-d8ec).
///
/// The fetch used to walk through it: the sub-page's blocks joined the
/// parent's list, so the base handed the push ids that live inside the
/// sub-page and the next round wrote the parent page's text in there. The
/// user's report is the last test here, end to end.
@MainActor
final class CraftSubPageSyncTests: XCTestCase {
    private let base = URL(string: "https://connect.craft.do/links/test/api/v1")!

    private func defaults(_ name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func adapter(_ store: UserDefaults, _ transport: NormalisingCraftTransport)
        -> (NotesAdapter, CraftNoteDestination) {
        let destination = CraftNoteDestination(defaults: store)
        let adapter = NotesAdapter(defaults: store, defaultName: "Note",
                                   notesDirectory: freshNotesDirectory(),
                                   destination: destination)
        adapter.craftTransport = transport
        adapter.craftBaseURLOverride = base
        return (adapter, destination)
    }

    private func syncedPad(_ adapter: NotesAdapter, _ destination: CraftNoteDestination,
                           text: String) async throws -> UUID {
        let id = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = text
        await adapter.flushCraftPush()
        XCTAssertEqual(destination.craftDocumentID(for: id), "doc1", "the push provisioned")
        return id
    }

    func testSubPageContentNeverEntersThePad() async throws {
        let name = "ccp.subpage.pad.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (adapter, destination) = adapter(store, transport)
        _ = try await syncedPad(adapter, destination, text: "one\n\ntwo")

        transport.blocks.append(.init(id: "sub", markdown: "notes",
                                      children: [.init(id: "inside", markdown: "secret")]))
        await adapter.pullAll()

        XCTAssertEqual(adapter.text, "one\n\ntwo",
                       "what the sub-page holds belongs to the sub-page")
    }

    func testEditingThePadNeverWritesInsideASubPage() async throws {
        // The report: add a sub-page in Craft, come back and type, and the
        // whole parent page is inside the sub-page when you look again.
        let name = "ccp.subpage.push.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (adapter, destination) = adapter(store, transport)
        _ = try await syncedPad(adapter, destination, text: "one\n\ntwo")
        let parentIDs = transport.blocks.map(\.id)

        transport.blocks.append(.init(id: "sub", markdown: "notes",
                                      children: [.init(id: "inside", markdown: "secret")]))
        await adapter.pullAll()
        adapter.text = "one\n\ntwo\n\nthree"
        await adapter.flushCraftPush()

        let subPage = try XCTUnwrap(transport.blocks.first { $0.id == "sub" })
        XCTAssertEqual(subPage.children.map(\.markdown), ["secret"],
                       "the pad's text must never land inside the sub-page")
        XCTAssertEqual(transport.blocks.filter { $0.children.isEmpty }.map(\.markdown),
                       ["one", "two", "three"],
                       "the parent page keeps its own blocks and gains the new one")
        XCTAssertEqual(Array(transport.blocks.map(\.id).prefix(2)), parentIDs,
                       "the original blocks keep their ids — nothing was deleted and reposted")
    }
}
