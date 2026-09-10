// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPKit

/// The pull decision table. Every question is asked of the recorded base by
/// string equality, each side in its own dialect — so Craft respelling what
/// it stores is invisible here, which is the point of the base (ccp-c2x5).
final class CraftPullTests: XCTestCase {
    private func block(_ id: String, _ markdown: String?) -> FetchedBlock {
        FetchedBlock(id: id, markdown: markdown)
    }

    /// A base whose two sides agree, ids `a`, `b`, … in order.
    private func base(_ markdowns: [String], local: String? = nil) -> PadSyncBase {
        PadSyncBase(localText: local ?? CraftPull.join(markdowns),
                    blocks: zip("abcdefg", markdowns).map {
                        BaseBlock(id: String($0), markdown: $1,
                                  isWritable: !CraftBlockPolicy.isUnwritable(markdown: $1))
                    })
    }

    // MARK: - Joining

    func testJoinUsesHardBreaksSoPulledTextRendersTight() {
        XCTAssertEqual(CraftPull.join(["one", "two"]), "one  \ntwo")
        XCTAssertEqual(CraftPull.join([]), "")
    }

    func testJoinedTextResplitsIntoTheSameBlocks() {
        // The round-trip the loop quiets on: join must be the splitter's
        // inverse, lists included.
        let texts = ["one", "- a", "- b", "> q"]
        let slices = CraftBlockSplitter.slices(in: CraftPull.join(texts))
        XCTAssertEqual(slices.map(\.markdown), texts)
    }

    /// ccp-hw0, the full local round trip: to-dos in both states survive
    /// split → join → resplit byte-identical.
    func testTaskListStatesSurviveTheJoinRoundTrip() {
        let slices = CraftBlockSplitter.slices(in: "- [ ] open\n- [x] done\n")
        let roundTripped = CraftBlockSplitter.slices(in: CraftPull.join(slices.map(\.markdown)))
        XCTAssertEqual(roundTripped.map(\.markdown), ["- [ ] open", "- [x] done"])
    }

    // MARK: - Seeding the base from a fetch

    func testRemoteBlocksTakeCraftsTextAndThePolicysWritableFlag() {
        let seeded = PadSyncBase.remote([block("a", "plain"),
                                         block("b", "<collection>nope</collection>")])
        XCTAssertEqual(seeded.map(\.id), ["a", "b"])
        XCTAssertEqual(seeded.map(\.markdown), ["plain", "<collection>nope</collection>"])
        XCTAssertTrue(seeded[0].isWritable)
        XCTAssertFalse(seeded[1].isWritable, "Craft will not take this back")
    }

    func testBlocksCraftCarriesNoMarkdownForStayOutOfTheBase() {
        // An image pins nothing: the push only names ids the base holds, so
        // leaving it out is what guarantees it is never rewritten.
        XCTAssertEqual(PadSyncBase.remote([block("a", "one"), block("img", nil)]).map(\.id),
                       ["a"])
    }

    // MARK: - The four cases

    func testConvergedWhenNeitherSideMoved() {
        XCTAssertEqual(CraftPull.decide(local: "one  \ntwo", base: base(["one", "two"]),
                                        remote: [block("a", "one"), block("b", "two")]),
                       .converged)
    }

    func testCraftRespellingTheBaseIsNotAMove() {
        // The bug this whole design exists to kill: our side of the base is
        // our markdown, Craft's side is Craft's, and neither is compared
        // against the other.
        let recorded = PadSyncBase(localText: "an _italic_ word",
                                   blocks: [BaseBlock(id: "a", markdown: "an *italic* word")])
        XCTAssertEqual(CraftPull.decide(local: "an _italic_ word", base: recorded,
                                        remote: [block("a", "an *italic* word")]),
                       .converged)
    }

    func testCleanPadAdoptsRemoteEdits() {
        let decision = CraftPull.decide(local: "one", base: base(["one"]),
                                        remote: [block("a", "ONE")])
        XCTAssertEqual(decision, .adopt(text: "ONE",
                                        base: PadSyncBase(localText: "ONE",
                                                          blocks: PadSyncBase.remote([block("a", "ONE")]))))
    }

    func testCleanPadTakesNewIdsWhenCraftSplitABlock() {
        // Same text, two blocks now: the pad keeps its text but takes the
        // ids, or links die on the next push.
        guard case .adopt(let text, let adopted) = CraftPull.decide(
            local: "one", base: base(["one"]),
            remote: [block("a", "one"), block("b", "one")])
        else { return XCTFail("expected adopt") }
        XCTAssertEqual(text, "one  \none")
        XCTAssertEqual(adopted.blocks.map(\.id), ["a", "b"])
    }

    func testLocalEditsSkipWhenCraftDidNotMove() {
        XCTAssertEqual(CraftPull.decide(local: "one edited", base: base(["one"]),
                                        remote: [block("a", "one")]),
                       .skip)
    }

    func testRemoteDeleteAdoptsOnAnUnmovedPad() {
        XCTAssertEqual(CraftPull.decide(local: "one  \ntwo", base: base(["one", "two"]),
                                        remote: [block("a", "one")]),
                       .adopt(text: "one",
                              base: PadSyncBase(localText: "one",
                                                blocks: PadSyncBase.remote([block("a", "one")]))))
    }

    func testEmptySidesConverge() {
        XCTAssertEqual(CraftPull.decide(local: "", base: PadSyncBase(), remote: []), .converged)
    }

    // MARK: - Both sides moved

    func testDisjointEditsMergeWithoutAConflict() {
        guard case .merged(let text, let hadConflict, _, _) = CraftPull.decide(
            local: "ONE  \ntwo", base: base(["one", "two"]),
            remote: [block("a", "one"), block("b", "TWO")])
        else { return XCTFail("expected merged") }
        XCTAssertEqual(text, "ONE  \nTWO", "both edits survive")
        XCTAssertFalse(hadConflict, "different blocks is not a disagreement")
    }

    func testTheSameBlockChangedBothWaysKeepsThePanelAndFlags() {
        guard case .merged(let text, let hadConflict, let remoteText, _) = CraftPull.decide(
            local: "mine", base: base(["one"]), remote: [block("a", "theirs")])
        else { return XCTFail("expected merged") }
        XCTAssertEqual(text, "mine", "the panel's text is what the user last saw")
        XCTAssertTrue(hadConflict)
        XCTAssertEqual(remoteText, "theirs", "Craft's version stays reachable in history")
    }

    func testARespelledBlockIsNotCountedAsCraftsEditDuringAMerge() {
        // Craft's side of the base is what its blocks are diffed against, so
        // its own spelling never reads as an edit someone made there.
        let recorded = PadSyncBase(localText: "an _italic_ word  \ntwo",
                                   blocks: [BaseBlock(id: "a", markdown: "an *italic* word"),
                                            BaseBlock(id: "b", markdown: "two")])
        guard case .merged(_, let hadConflict, _, _) = CraftPull.decide(
            local: "an _italic_ word, edited  \ntwo", base: recorded,
            remote: [block("a", "an *italic* word"), block("b", "TWO")])
        else { return XCTFail("expected merged") }
        XCTAssertFalse(hadConflict)
    }

    func testMergeThatChangesNothingLocallySkipsForThePush() {
        // Craft's move was already in the pad: the local lead still needs
        // pushing, and there is nothing to adopt.
        XCTAssertEqual(CraftPull.decide(local: "one  \nTWO", base: base(["one", "two"]),
                                        remote: [block("a", "one"), block("b", "TWO")]),
                       .skip)
    }

    func testClearedPadKeepsTheClearWhenCraftAlsoMoved() {
        guard case .merged(let text, _, _, _) = CraftPull.decide(
            local: "", base: base(["one"]), remote: [block("a", "ONE")])
        else { return XCTFail("expected merged") }
        XCTAssertEqual(text, "", "clearing the pad is an edit like any other")
    }

    // MARK: - First sight

    func testHandMappedPadKeepsBothSidesAndStartsRemembering() {
        // No base and both sides hold text: adopting would wipe local text
        // Craft never confirmed, and pushing would wipe Craft's. Record the
        // agreement instead and let the next real edit decide.
        guard case .seed(let seeded) = CraftPull.decide(
            local: "my notes", base: PadSyncBase(), remote: [block("a", "theirs")])
        else { return XCTFail("expected seed") }
        XCTAssertEqual(seeded.localText, "my notes")
        XCTAssertEqual(seeded.blocks.map(\.markdown), ["theirs"])
    }

    func testEmptyPadAdoptsOnFirstPull() {
        XCTAssertEqual(CraftPull.decide(local: "", base: PadSyncBase(),
                                        remote: [block("a", "theirs")]),
                       .adopt(text: "theirs",
                              base: PadSyncBase(localText: "theirs",
                                                blocks: PadSyncBase.remote([block("a", "theirs")]))))
    }

    // MARK: - Legacy conflict copies

    func testLegacyStashBlocksStayOutOfThePad() {
        // Sections an older build appended to the Craft document: excluded
        // from the pad, left in Craft for the user to clear.
        let remote = [block("r1", "theirs"),
                      block("c1", "# Conflicted copy"),
                      block("c2", "mine")]
        var recorded = base(["theirs"], local: "theirs")
        recorded.blocks[0].id = "r1"
        XCTAssertEqual(CraftPull.decide(local: "theirs", base: recorded,
                                        remote: remote, stashIDs: ["c1", "c2"]),
                       .converged)
    }

    func testClearingAStashCopyInCraftHealsQuietly() {
        var recorded = base(["theirs"], local: "theirs")
        recorded.blocks[0].id = "r1"
        XCTAssertEqual(CraftPull.decide(local: "theirs", base: recorded,
                                        remote: [block("r1", "theirs")], stashIDs: ["c1"]),
                       .converged)
    }

    func testHealedPolicyBlockBecomesWritableAgain() {
        // A block the policy once called unwritable, fixed in Craft to plain
        // markdown: policy is re-read every pull, only stash copies stay out.
        let tagged = "<collection>nope</collection>"
        guard case .adopt(_, let adopted) = CraftPull.decide(
            local: tagged, base: base([tagged]), remote: [block("a", "plain hello")])
        else { return XCTFail("expected adopt") }
        XCTAssertTrue(adopted.blocks[0].isWritable)
    }
}
