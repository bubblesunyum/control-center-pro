// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

/// A base whose two sides no longer stand one-to-one used to make the push
/// delete every writable block and repost the whole pad (ccp-hu51).
///
/// Two things were wrong. The merge recorded the *old* local text beside the
/// *new* block list, so any round where Craft gained or lost a block left the
/// base misaligned — routine, not rare. And the misaligned path itself tore
/// the document down and rebuilt it, losing every block id along with
/// whatever Craft held that markdown cannot express.
@MainActor
final class CraftRealignSyncTests: XCTestCase {
    private let baseURL = URL(string: "https://connect.craft.do/links/test/api/v1")!

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
        adapter.craftBaseURLOverride = baseURL
        return (adapter, destination)
    }

    // MARK: - The report, end to end

    func testABlockAddedInCraftWhileThePadIsDirtyDoesNotRebuildTheDocument() async throws {
        // Craft gains a block while the pad holds an unpushed edit: the
        // ordinary both-moved round. It used to leave the base misaligned,
        // and the push that followed deleted all three blocks and reposted
        // the pad — Craft's own new block destroyed and re-created with it.
        let name = "ccp.realign.remoteadd.\(UUID().uuidString)"
        let store = try defaults(name)
        defer { store.removePersistentDomain(forName: name) }
        let transport = NormalisingCraftTransport()
        let (adapter, destination) = adapter(store, transport)
        let id = try XCTUnwrap(adapter.selectedNoteID)
        destination.setCraftDocumentID("doc1", for: id)
        destination.storeSyncedTitle(adapter.selectedNoteName, for: id)
        destination.storeBase(.fixture("one  \ntwo"), for: id)
        transport.blocks = [.init(id: "block-0", markdown: "one"),
                            .init(id: "block-1", markdown: "two"),
                            .init(id: "block-2", markdown: "three")]
        adapter.text = "ONE  \ntwo"

        await adapter.pullAll()
        XCTAssertEqual(adapter.text, "ONE  \ntwo  \nthree", "the merge took both moves")
        await adapter.flushCraftPush()

        XCTAssertEqual(transport.blocks.map(\.id), ["block-0", "block-1", "block-2"],
                       "every block keeps its id — the document was not rebuilt")
        XCTAssertEqual(transport.blocks.map(\.markdown), ["ONE", "two", "three"],
                       "only the block the pad actually edited was written")
        XCTAssertFalse(transport.writes.contains { $0.method == "DELETE" },
                       "nothing was deleted")
        XCTAssertEqual(transport.writtenMarkdown, [["ONE"]],
                       "one block re-sent, not the whole pad")
    }

    func testTheMergedBaseStandsOneToOneSoTheNextPushIsSurgical() async throws {
        let base = PadSyncBase.fixture("one  \ntwo")
        let fetched = [BaseBlock(id: "block-0", markdown: "one"),
                       BaseBlock(id: "block-1", markdown: "two"),
                       BaseBlock(id: "block-2", markdown: "three")]

        guard case .merged(_, _, _, let advanced) = CraftPull.decide(
            local: "ONE  \ntwo", base: base,
            remote: fetched.map { FetchedBlock(id: $0.id, markdown: $0.markdown) })
        else { return XCTFail("both sides moved") }

        XCTAssertTrue(advanced.isAligned, "the recorded base pairs slice to block")
        XCTAssertEqual(advanced.localSlices, ["one", "two", "three"],
                       "a block new to us is agreed at Craft's own text — the merge "
                       + "already put it in the pad, so the push must not post it again")
    }

    func testARespelledBlockStaysAgreedAcrossAMerge() async throws {
        // The base is deliberately asymmetric: we hold `_x_`, Craft respelled
        // it to `*x*`. Carrying the local side by id keeps that asymmetry, so
        // the round does not re-send a block nobody touched (ccp-c2x5).
        let base = PadSyncBase(localText: "_x_  \ntwo",
                               blocks: [BaseBlock(id: "block-0", markdown: "*x*"),
                                        BaseBlock(id: "block-1", markdown: "two")])
        let remote = [FetchedBlock(id: "block-0", markdown: "*x*"),
                      FetchedBlock(id: "block-1", markdown: "two"),
                      FetchedBlock(id: "block-2", markdown: "three")]

        guard case .merged(let text, _, _, let advanced) = CraftPull.decide(
            local: "_x_  \nTWO", base: base, remote: remote)
        else { return XCTFail("both sides moved") }

        XCTAssertEqual(advanced.localSlices.first, "_x_",
                       "our spelling of an untouched block survives the merge")
        XCTAssertEqual(BlockPushPlan.plan(from: advanced,
                                          to: CraftBlockSplitter.slices(in: text).map(\.markdown)),
                       BlockPushPlan(updates: [BlockUpdate(id: "block-1", markdown: "TWO")]),
                       "only the edited block is written")
    }

    // MARK: - The misaligned path itself

    /// A base Craft has split under: one local slice, two Craft blocks.
    private func splitBase() -> PadSyncBase {
        PadSyncBase(localText: "a", blocks: [BaseBlock(id: "block-0", markdown: "a"),
                                             BaseBlock(id: "block-1", markdown: "b")])
    }

    func testAMisalignedPushKeepsTheIdsItCanAndWritesOnlyWhatDiffers() async throws {
        let plan = BlockPushPlan.plan(from: splitBase(), to: ["A", "b"])

        XCTAssertEqual(plan, BlockPushPlan(updates: [BlockUpdate(id: "block-0", markdown: "A")]),
                       "the predecessor deleted both blocks and reposted both slices")
    }

    func testAMisalignedPushLeavesARespelledBlockNobodyTouchedAlone() async throws {
        // Review finding: pairing our slices against Craft's blocks and
        // diffing them is ccp-c2x5 — a block Craft respelled reads as
        // changed. The top-level guard only proves the *pad* moved, never
        // that this block did, so one edit anywhere used to drag every
        // respelled block along with it and PUT our stale spelling over
        // whatever Craft now held.
        let base = PadSyncBase(
            localText: "_x_  \n_y_",
            blocks: [BaseBlock(id: "block-0", markdown: "*x*"),
                     BaseBlock(id: "block-1", markdown: "*y*"),
                     BaseBlock(id: "block-2", markdown: "extra")])
        XCTAssertFalse(base.isAligned, "two slices, three blocks")

        XCTAssertEqual(BlockPushPlan.plan(from: base, to: ["_X_", "_y_"]),
                       BlockPushPlan(updates: [BlockUpdate(id: "block-0", markdown: "_X_")],
                                     deletes: ["block-2"]),
                       "only the block the pad actually edited is written")
    }

    func testAMisalignedPushPostsLeftoverSlicesAfterTheLastBlockItKept() async throws {
        let plan = BlockPushPlan.plan(from: splitBase(), to: ["a", "b", "c"])

        XCTAssertEqual(plan, BlockPushPlan(inserts: [BlockInsert(afterID: "block-1", markdown: "c")]),
                       "new text joins the end of the pad's own run")
    }

    func testAMisalignedPushDeletesOnlyTheBlocksThePadNoLongerHas() async throws {
        let base = PadSyncBase(localText: "a",
                               blocks: [BaseBlock(id: "block-0", markdown: "a"),
                                        BaseBlock(id: "block-1", markdown: "b"),
                                        BaseBlock(id: "block-2", markdown: "c")])

        XCTAssertEqual(BlockPushPlan.plan(from: base, to: ["A"]),
                       BlockPushPlan(updates: [BlockUpdate(id: "block-0", markdown: "A")],
                                     deletes: ["block-1", "block-2"]),
                       "the surplus goes; the block the pad still holds keeps its id")
    }

    func testAMisalignedPushNeverWritesOrDeletesAPinnedBlock() async throws {
        let base = PadSyncBase(
            localText: "a",
            blocks: [BaseBlock(id: "block-0", markdown: "a"),
                     BaseBlock(id: "card", markdown: "<card>c</card>", isWritable: false)])

        XCTAssertEqual(BlockPushPlan.plan(from: base, to: ["a", "<card>c</card>", "new"]),
                       BlockPushPlan(inserts: [BlockInsert(afterID: "card", markdown: "new")]),
                       "what Craft owns is left alone and anchors what follows it")
    }
}
