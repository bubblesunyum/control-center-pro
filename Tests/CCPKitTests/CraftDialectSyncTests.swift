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

    /// A pad whose first push provisioned its document and landed — the
    /// steady state every later round starts from. The document is created by
    /// the push, as in production: a pad handed a document id it never wrote
    /// to is the migration case, and that one waits for a pull.
    private func syncedPad(_ adapter: NotesAdapter, _ destination: CraftNoteDestination,
                           text: String) async throws -> UUID {
        let id = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = text
        await adapter.flushCraftPush()
        XCTAssertEqual(destination.craftDocumentID(for: id), "doc1", "the push provisioned")
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

/// Upgrading from the superseded sidecar (ccp-c2x5): a mapped pad has no base
/// until a pull seeds one, and planning from nothing would post the whole pad
/// into a document that already holds it.
@MainActor
final class CraftBaseMigrationTests: XCTestCase {
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

    /// A pad whose first push provisioned its document and landed.
    private func syncedPad(_ adapter: NotesAdapter, _ destination: CraftNoteDestination,
                           text: String) async throws -> UUID {
        let id = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = text
        await adapter.flushCraftPush()
        return id
    }

    func testAMappedPadWithNoBaseWaitsForThePullInsteadOfReposting() async throws {
        let name = "ccp.migrate.wait.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport(blocks: [.init(id: "old", markdown: "my note")])
        let (adapter, destination) = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)
        // What an upgrade looks like: a mapping, a title, and no base.
        destination.setCraftDocumentID("doc1", for: id)
        destination.storeSyncedTitle(adapter.selectedNoteName, for: id)
        adapter.text = "my note, edited"

        await adapter.flushCraftPush()

        XCTAssertTrue(transport.writes.isEmpty,
                      "nothing may be written before there is a base to diff against")
        XCTAssertEqual(transport.blocks.map(\.markdown), ["my note"])
        XCTAssertTrue(adapter.isPushDirty(id), "the edit is held, not dropped")

        // The pull records what each side holds and moves neither: which one
        // leads is not knowable, so the next real edit decides.
        await adapter.pullAll()
        XCTAssertEqual(adapter.text, "my note, edited")
        XCTAssertEqual(transport.blocks.map(\.markdown), ["my note"])

        // And that edit lands in place, against the seeded base.
        adapter.text = "my note, edited twice"
        await adapter.flushCraftPush()

        XCTAssertEqual(transport.blocks.map(\.markdown), ["my note, edited twice"],
                       "the edit lands in place — no second copy")
    }

    func testAFailedRoundDiffsAgainstWhatCraftReallyHolds() async throws {
        // The DELETE fails, so Craft keeps a block the pad dropped. The base
        // records Craft's text as both sides, so the pad reads as leading and
        // the next round removes it — rather than replaying a plan that half
        // happened, which would repost what the POST already landed.
        let name = "ccp.migrate.partial.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (adapter, destination) = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)
        destination.setCraftDocumentID("doc1", for: id)
        destination.storeSyncedTitle(adapter.selectedNoteName, for: id)
        adapter.text = "one\n\ntwo\n\nthree"
        destination.storeBase(.fixture("one\n\ntwo\n\nthree"), for: id)
        // Seed Craft with the same three blocks under the base's ids.
        transport.blocks = ["one", "two", "three"].enumerated().map {
            .init(id: "block-\($0.offset)", markdown: $0.element)
        }
        transport.failDelete = true

        adapter.text = "one\n\nTWO"
        await adapter.flushCraftPush()

        XCTAssertEqual(transport.blocks.map(\.markdown), ["one", "TWO", "three"],
                       "the update landed; the delete did not")
        XCTAssertEqual(destination.base(for: id).localText, "one  \nTWO  \nthree",
                       "a failed round records what Craft really holds, on both sides")

        transport.failDelete = false
        await adapter.flushCraftPush()

        XCTAssertEqual(transport.blocks.map(\.markdown), ["one", "TWO"],
                       "the retry removes the orphan instead of reposting")
    }

    func testARetryingPushDoesNotRecordTheSameConflictTwice() async throws {
        // Review finding: a stalled push leaves the pad unmerged into Craft,
        // and every panel reopen used to re-derive the same merge and append
        // another conflict record. The base's remote side advances at the
        // merge, so the second pull has nothing left to integrate.
        let name = "ccp.migrate.reconflict.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (adapter, destination) = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)
        destination.setCraftDocumentID("doc1", for: id)
        destination.storeSyncedTitle(adapter.selectedNoteName, for: id)
        adapter.text = "mine"
        // Agreed on "one"; since then the panel typed "mine" and Craft moved
        // the same block to "theirs".
        destination.storeBase(.fixture("one"), for: id)
        transport.blocks = [.init(id: "block-0", markdown: "theirs")]

        await adapter.pullAll()
        XCTAssertEqual(adapter.text, "mine", "the panel wins the block both sides changed")
        XCTAssertEqual(adapter.conflicts(for: id).count, 1)

        // The push never lands; the panel is opened again.
        await adapter.pullAll()

        XCTAssertEqual(adapter.conflicts(for: id).count, 1,
                       "one disagreement is one record, however often it is seen")
        XCTAssertEqual(adapter.snapshots(for: id).filter { $0.reason == .conflict }.count, 1)
    }

    func testABlockAddedInCraftDuringThePushIsNotBuried() async throws {
        // Review finding: the read-back that records the agreement sees the
        // whole document, so a block someone added in Craft while the round
        // was away would enter the base as already-agreed and never reach
        // the pad. Only blocks this round knew or created may be agreed to.
        let name = "ccp.migrate.foreign.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (adapter, destination) = adapter(store, transport)
        let id = try await syncedPad(adapter, destination, text: "one")

        // Someone writes in Craft between our PUT and the read-back.
        transport.onWrite = { [weak transport] in
            transport?.blocks.append(.init(id: "foreign", markdown: "added in Craft"))
            transport?.onWrite = nil
        }
        adapter.text = "ONE"
        await adapter.flushCraftPush()

        XCTAssertFalse(destination.base(for: id).blocks.contains { $0.id == "foreign" },
                       "a block this round never touched is not something to agree to")

        await adapter.pullAll()

        XCTAssertTrue(adapter.text.contains("added in Craft"),
                      "it reaches the pad on the next pull, the ordinary way")
    }
}
