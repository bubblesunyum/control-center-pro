// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

/// Sync against a Craft that respells what it is given (ccp-c2x5).
///
/// Every assertion here is a property the user feels directly: the loop
/// quiets, a panel-only edit never provokes a conflict copy, and Craft's
/// own spelling is never mistaken for someone editing the document.
@MainActor
final class CraftDialectSyncTests: XCTestCase {
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

    /// A pad mapped to an empty Craft doc, with its first push already
    /// landed — the steady state every later round starts from.
    private func syncedPad(_ adapter: NotesAdapter, _ destination: CraftNoteDestination,
                           text: String) async throws -> UUID {
        let id = try XCTUnwrap(adapter.selectedNoteID)
        destination.setCraftDocumentID("doc1", for: id)
        destination.storeSyncedTitle(adapter.selectedNoteName, for: id)
        adapter.text = text
        await adapter.flushCraftPush()
        return id
    }

    func testEditingOneBlockDoesNotResendTheRespelledOne() async throws {
        // Defect 1 in one assertion: a block Craft respelled must not be
        // re-sent by every later round for the rest of the pad's life.
        let name = "ccp.dialect.quiet.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (adapter, destination) = adapter(store, transport)
        _ = try await syncedPad(adapter, destination, text: "an _italic_ word\n\nplain")
        XCTAssertEqual(transport.blocks.map(\.markdown), ["an *italic* word", "plain"])

        transport.writtenMarkdown.removeAll()
        adapter.text = "an _italic_ word\n\nplain, edited"
        await adapter.flushCraftPush()

        let resent = transport.writtenMarkdown.flatMap { $0 }
        XCTAssertFalse(resent.contains { $0.contains("italic") },
                       "the untouched block was respelled by Craft, not edited by the user")
        XCTAssertEqual(transport.blocks.map(\.markdown), ["an *italic* word", "plain, edited"])
    }

    func testPanelOnlyEditNeverPostsAConflictCopy() async throws {
        let name = "ccp.dialect.noconflict.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (adapter, destination) = adapter(store, transport)
        _ = try await syncedPad(adapter, destination, text: "an _italic_ word")

        // The panel alone moves; Craft is untouched by anyone.
        adapter.text = "an _italic_ word, extended"
        await adapter.flushCraftPush()
        let settled = transport.blocks.map(\.markdown)
        await adapter.pullAll()

        XCTAssertEqual(transport.blocks.map(\.markdown), settled,
                       "no conflict copy may be appended to the document")
        XCTAssertFalse(transport.blocks.contains { $0.markdown.contains("Conflicted copy") })
        XCTAssertEqual(adapter.text, "an _italic_ word, extended",
                       "the panel must keep what was typed in it")
    }

    func testRepeatedOpenAndCloseNeverAccumulatesBlocks() async throws {
        // The user's report: close and reopen the panel a few times and the
        // Craft document grows conflict copies of the panel's own text.
        let name = "ccp.dialect.reopen.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (adapter, destination) = adapter(store, transport)
        _ = try await syncedPad(adapter, destination, text: "todo\n\n- _one_\n- two")
        let settled = transport.blocks.map(\.markdown)

        for _ in 0..<3 {
            await adapter.pullAll()
            await adapter.flushCraftPush()
        }

        XCTAssertEqual(transport.blocks.map(\.markdown), settled,
                       "an idle open/close cycle must change nothing in Craft")
        XCTAssertEqual(adapter.text, "todo\n\n- _one_\n- two",
                       "an idle cycle must not rewrite the panel either")
    }

    func testCraftSplittingABlockIsNotAConflict() async throws {
        // Nobody touches Craft: it simply splits a soft-broken block of ours
        // into two of its own. That must not read as a remote edit.
        let name = "ccp.dialect.split.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (adapter, destination) = adapter(store, transport)
        _ = try await syncedPad(adapter, destination, text: "one _two_")

        // Craft re-renders the block into two, as it does for nested lists.
        transport.blocks = [.init(id: transport.blocks[0].id, markdown: "one"),
                            .init(id: "craft-split", markdown: "*two*")]
        await adapter.pullAll()

        XCTAssertFalse(transport.blocks.contains { $0.markdown.contains("Conflicted copy") },
                       "Craft reshaping its own blocks is not someone editing the document")
    }

    func testRemoteEditIsAdoptedNotConflicted() async throws {
        let name = "ccp.dialect.adopt.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (adapter, destination) = adapter(store, transport)
        _ = try await syncedPad(adapter, destination, text: "an _italic_ word")

        // Someone really does edit Craft, and the panel has not moved.
        transport.blocks[0].markdown = "an *italic* word, from Craft"
        await adapter.pullAll()

        XCTAssertEqual(adapter.text, "an *italic* word, from Craft")
        XCTAssertFalse(transport.blocks.contains { $0.markdown.contains("Conflicted copy") })
    }
}
