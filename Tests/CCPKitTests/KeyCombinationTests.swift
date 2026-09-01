// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Carbon.HIToolbox
import XCTest
@testable import CCPKit

final class KeyCombinationTests: XCTestCase {
    func testRoundTripsThroughItsStorageValue() {
        let combination = KeyCombination(keyCode: Int64(kVK_ANSI_K),
                                         modifiers: [.control, .option, .command])

        XCTAssertEqual(KeyCombination(storageValue: combination.storageValue), combination)
    }

    func testMalformedStorageValueIsNoCombinationAtAll() {
        XCTAssertNil(KeyCombination(storageValue: "command:"))
        XCTAssertNil(KeyCombination(storageValue: "meta:40"))
        XCTAssertNil(KeyCombination(storageValue: ""))
    }

    func testABareLetterIsNotValid() {
        XCTAssertFalse(KeyCombination(keyCode: Int64(kVK_ANSI_K), modifiers: []).isValid)
    }

    func testAFunctionKeyIsValidOnItsOwn() {
        XCTAssertTrue(KeyCombination(keyCode: Int64(kVK_F2), modifiers: []).isValid)
    }

    func testDisplayStringWritesTheModifiersAheadOfTheKey() {
        let combination = KeyCombination(keyCode: Int64(kVK_ANSI_K), modifiers: [.command, .shift])

        XCTAssertEqual(combination.displayString, "⇧⌘K")
    }

    func testDeleteAloneClearsButDeleteWithAModifierDoesNot() {
        XCTAssertTrue(KeyCombination.clearsShortcut(keyCode: Int64(kVK_Delete), modifiers: []))
        XCTAssertFalse(KeyCombination.clearsShortcut(keyCode: Int64(kVK_Delete),
                                                     modifiers: [.command]))
    }

    func testModifiersComeFromAnEventsFlags() {
        let modifiers = KeyCombination.Modifiers(eventFlags: [.command, .shift, .capsLock])

        XCTAssertEqual(modifiers, [.command, .shift])
    }
}
