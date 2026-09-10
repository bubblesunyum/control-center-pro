// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPKit

final class ThreeWayMergeTests: XCTestCase {
    private func merge(_ base: [String], _ ours: [String], _ theirs: [String])
        -> ThreeWayMerge.Result {
        ThreeWayMerge.merge(base: base, ours: ours, theirs: theirs)
    }

    func testNeitherSideMoved() {
        let result = merge(["a", "b"], ["a", "b"], ["a", "b"])
        XCTAssertEqual(result.merged, ["a", "b"])
        XCTAssertFalse(result.hadConflict)
    }

    func testOneSideOnly() {
        XCTAssertEqual(merge(["a", "b"], ["a", "B"], ["a", "b"]).merged, ["a", "B"])
        XCTAssertEqual(merge(["a", "b"], ["a", "b"], ["A", "b"]).merged, ["A", "b"])
    }

    func testDisjointEditsBothSurvive() {
        let result = merge(["a", "b", "c"], ["A", "b", "c"], ["a", "b", "C"])
        XCTAssertEqual(result.merged, ["A", "b", "C"])
        XCTAssertFalse(result.hadConflict, "different blocks is not a disagreement")
    }

    func testDisjointInsertsBothSurvive() {
        let result = merge(["a", "c"], ["a", "b", "c"], ["a", "c", "d"])
        XCTAssertEqual(result.merged, ["a", "b", "c", "d"])
        XCTAssertFalse(result.hadConflict)
    }

    func testDeleteOnOneSideSurvives() {
        let result = merge(["a", "b", "c"], ["a", "c"], ["a", "b", "C"])
        XCTAssertEqual(result.merged, ["a", "C"])
        XCTAssertFalse(result.hadConflict)
    }

    func testSameBlockChangedDifferentlyKeepsOursAndFlags() {
        let result = merge(["a", "b"], ["a", "ours"], ["a", "theirs"])
        XCTAssertEqual(result.merged, ["a", "ours"])
        XCTAssertTrue(result.hadConflict)
    }

    func testIdenticalEditsAreAgreement() {
        let result = merge(["a", "b"], ["a", "same"], ["a", "same"])
        XCTAssertEqual(result.merged, ["a", "same"])
        XCTAssertFalse(result.hadConflict, "two people fixing one typo is not a conflict")
    }

    func testTailAppendsFromBothSides() {
        let result = merge(["a"], ["a", "ours"], ["a", "theirs"])
        XCTAssertEqual(result.merged, ["a", "ours", "theirs"])
        XCTAssertFalse(result.hadConflict, "appending at the end loses nothing")
    }

    func testGrowingAnEmptyBaseFromBothSides() {
        let result = merge([], ["ours"], ["theirs"])
        XCTAssertEqual(result.merged, ["ours", "theirs"])
    }

    func testWholeSideCleared() {
        XCTAssertEqual(merge(["a", "b"], [], ["a", "b"]).merged, [])
        XCTAssertEqual(merge(["a", "b"], ["a", "b"], []).merged, [])
    }

    func testInsertBesideAnEditOnTheOtherSide() {
        let result = merge(["a", "b"], ["a", "new", "b"], ["a", "B"])
        XCTAssertEqual(result.merged, ["a", "new", "B"])
        XCTAssertFalse(result.hadConflict)
    }
}
