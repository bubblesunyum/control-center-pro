// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPKit

/// The pull decision table: converge when both sides agree, adopt when local
/// adds nothing unpushed, stash-and-adopt on a real conflict, and never touch
/// local text otherwise. Confirmation is the push plan, never the dirty bit.
final class CraftPullTests: XCTestCase {
    private func block(_ id: String, _ markdown: String?) -> FetchedBlock {
        FetchedBlock(id: id, markdown: markdown)
    }

    private func sidecar(_ prints: [(String, String)], writable: Bool = true) -> BlockSidecar {
        BlockSidecar(entries: prints.map { BlockSidecarEntry(id: $0.0, fingerprint: $0.1,
                                                             isWritable: writable) })
    }

    private func fingerprint(_ markdown: String) -> String {
        BlockSidecar.fingerprint(markdown)
    }

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

    func testSeedPinsEveryBlockInOrderMarkingPolicyFailuresUnwritable() {
        let remote = [block("a", "plain"),
                      block("b", "<collection>nope</collection>"),
                      block("c", nil)]
        let seeded = CraftPull.seed(remote)
        XCTAssertEqual(seeded.entries.map(\.id), ["a", "b", "c"])
        XCTAssertTrue(seeded.entries[0].isWritable)
        XCTAssertFalse(seeded.entries[1].isWritable)
        XCTAssertFalse(seeded.entries[2].isWritable)
        XCTAssertEqual(seeded.entries[0].fingerprint, fingerprint("plain"))
    }

    func testConvergedWhenBothSidesAgree() {
        let decision = CraftPull.decide(local: "one  \ntwo",
                                        sidecar: sidecar([("a", fingerprint("one")),
                                                          ("b", fingerprint("two"))]),
                                        remote: [block("a", "one"), block("b", "two")])
        XCTAssertEqual(decision, .converged)
    }

    func testOwnPushBumpConvergesInsteadOfStashing() {
        // Identical text and ids: our own unconfirmed push moved no text —
        // nothing for a stash to save.
        let decision = CraftPull.decide(local: "one",
                                        sidecar: sidecar([("a", fingerprint("one"))]),
                                        remote: [block("a", "one")])
        XCTAssertEqual(decision, .converged)
    }

    func testCleanPadAdoptsRemoteEdits() {
        let decision = CraftPull.decide(local: "one",
                                        sidecar: sidecar([("a", fingerprint("one"))]),
                                        remote: [block("a", "ONE")])
        XCTAssertEqual(decision, .adopt(text: "ONE",
                                        sidecar: CraftPull.seed([block("a", "ONE")])))
    }

    func testCleanPadReseedsWhenOnlyIdsChanged() {
        // Same text, Craft split the block: the pad keeps its text but takes
        // the ids, or links die on the next push.
        let decision = CraftPull.decide(local: "one",
                                        sidecar: sidecar([("a", fingerprint("one"))]),
                                        remote: [block("a", "one"), block("b", "one")])
        if case .adopt(let text, let seeded) = decision {
            XCTAssertEqual(text, "one  \none")
            XCTAssertEqual(seeded.entries.map(\.id), ["a", "b"])
        } else {
            XCTFail("expected adopt, got \(decision)")
        }
    }

    func testLocalEditsSkipWhenRemoteDidNotMove() {
        let decision = CraftPull.decide(local: "one edited",
                                        sidecar: sidecar([("a", fingerprint("one"))]),
                                        remote: [block("a", "one")])
        XCTAssertEqual(decision, .skip)
    }

    func testLocalEditsConflictWhenRemoteMoved() {
        let decision = CraftPull.decide(local: "one edited",
                                        sidecar: sidecar([("a", fingerprint("one"))]),
                                        remote: [block("a", "ONE")])
        if case .conflict(let heading, let stash, let text, let seeded) = decision {
            XCTAssertEqual(heading, "# Conflicted copy")
            XCTAssertEqual(stash, ["one edited"])
            XCTAssertEqual(text, "ONE")
            XCTAssertEqual(seeded, CraftPull.seed([block("a", "ONE")]))
        } else {
            XCTFail("expected conflict, got \(decision)")
        }
    }

    func testHandMappedPadStashesInsteadOfWiping() {
        // No sidecar and both sides hold text: the local text was never
        // confirmed, so adopting would wipe it silently — dirty bit or not.
        let decision = CraftPull.decide(local: "my notes",
                                        sidecar: BlockSidecar(),
                                        remote: [block("a", "theirs")])
        if case .conflict(_, let stash, let text, _) = decision {
            XCTAssertEqual(stash, ["my notes"])
            XCTAssertEqual(text, "theirs")
        } else {
            XCTFail("expected conflict, got \(decision)")
        }
    }

    func testEmptyPadSeedsOnFirstPull() {
        let decision = CraftPull.decide(local: "",
                                        sidecar: BlockSidecar(),
                                        remote: [block("a", "theirs")])
        XCTAssertEqual(decision, .adopt(text: "theirs",
                                        sidecar: CraftPull.seed([block("a", "theirs")])))
    }

    func testClearedPadSkipsSoThePushOwnsTheDelete() {
        // Cleared while Craft moved: the empty text over confirmed blocks is
        // an unconfirmed delete, not "nothing to lose" — adopting would wipe
        // the clear and clear its dirty bit with it.
        let decision = CraftPull.decide(local: "",
                                        sidecar: sidecar([("a", fingerprint("one"))]),
                                        remote: [block("a", "ONE")])
        XCTAssertEqual(decision, .skip)
    }

    func testEmptySidesConverge() {
        let decision = CraftPull.decide(local: "", sidecar: BlockSidecar(), remote: [])
        XCTAssertEqual(decision, .converged)
    }

    func testRemoteDeleteAdoptsOnAConfirmedPad() {
        let decision = CraftPull.decide(local: "one  \ntwo",
                                        sidecar: sidecar([("a", fingerprint("one")),
                                                          ("b", fingerprint("two"))]),
                                        remote: [block("a", "one")])
        XCTAssertEqual(decision, .adopt(text: "one",
                                        sidecar: CraftPull.seed([block("a", "one")])))
    }

    func testRemoteDeleteWithLocalEditsConflicts() {
        let decision = CraftPull.decide(local: "one edited  \ntwo",
                                        sidecar: sidecar([("a", fingerprint("one")),
                                                          ("b", fingerprint("two"))]),
                                        remote: [block("a", "one")])
        if case .conflict(_, let stash, let text, _) = decision {
            XCTAssertEqual(stash, ["one edited", "two"])
            XCTAssertEqual(text, "one")
        } else {
            XCTFail("expected conflict, got \(decision)")
        }
    }

    func testStashPinsStayOutOfThePad() {
        // The round after a conflict: the stash lives in Craft and in the
        // sidecar, and the next pull must neither join it into the pad nor
        // re-mark it writable.
        let remote = [block("r1", "theirs"),
                      block("c1", "# Conflicted copy"),
                      block("c2", "mine")]
        var seeded = CraftPull.seed(remote)
        seeded.entries[1].isWritable = false
        seeded.entries[2].isWritable = false
        let decision = CraftPull.decide(local: "theirs", sidecar: seeded, remote: remote,
                                        stashIDs: ["c1", "c2"])
        XCTAssertEqual(decision, .converged)
    }

    func testDeletedStashHealsOutOfTheSidecar() {
        // The user cleared the conflict copy in Craft: the pins drop on the
        // next adopt instead of deleting or duplicating.
        var seeded = CraftPull.seed([block("r1", "theirs"), block("c1", "# Conflicted copy")])
        seeded.entries[1].isWritable = false
        let decision = CraftPull.decide(local: "theirs", sidecar: seeded,
                                        remote: [block("r1", "theirs")],
                                        stashIDs: ["c1"])
        XCTAssertEqual(decision, .adopt(text: "theirs",
                                        sidecar: CraftPull.seed([block("r1", "theirs")])))
    }

    func testHealedPolicyBlockRejoinsThePad() {
        // A block the policy once called unwritable, fixed in Craft to plain
        // markdown: it must come back as a normal block — pins for policy
        // are re-evaluated every pull, only stash copies stay out.
        let tagged = "<collection>nope</collection>"
        let seeded = CraftPull.seed([block("p1", tagged)])
        XCTAssertFalse(seeded.entries[0].isWritable)
        let decision = CraftPull.decide(local: tagged, sidecar: seeded,
                                        remote: [block("p1", "plain hello")])
        if case .adopt(let text, let adopted) = decision {
            XCTAssertEqual(text, "plain hello")
            XCTAssertTrue(adopted.entries[0].isWritable)
        } else {
            XCTFail("expected adopt, got \(decision)")
        }
    }
}
