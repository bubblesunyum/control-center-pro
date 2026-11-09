// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPKit

/// The hold-to-peek rule: quick taps toggle and stay, holds hide on release.
final class HotkeyHoldPolicyTests: XCTestCase {
    func testPressShowsOnlyWhileHidden() {
        XCTAssertTrue(HotkeyHoldPolicy.shouldShowOnPress(isVisible: false))
        XCTAssertFalse(HotkeyHoldPolicy.shouldShowOnPress(isVisible: true))
    }

    func testQuickTapWhileHiddenStaysUp() {
        XCTAssertFalse(HotkeyHoldPolicy.shouldHideOnRelease(
            wasVisibleAtPress: false, pressDuration: 0.2
        ))
    }

    func testHoldWhileHiddenHidesOnRelease() {
        XCTAssertTrue(HotkeyHoldPolicy.shouldHideOnRelease(
            wasVisibleAtPress: false, pressDuration: 1.5
        ))
    }

    func testThresholdItselfCountsAsAHold() {
        XCTAssertTrue(HotkeyHoldPolicy.shouldHideOnRelease(
            wasVisibleAtPress: false,
            pressDuration: HotkeyHoldPolicy.holdThreshold
        ))
    }

    func testReleaseWhileVisibleAlwaysHides() {
        XCTAssertTrue(HotkeyHoldPolicy.shouldHideOnRelease(
            wasVisibleAtPress: true, pressDuration: 0.2
        ))
        XCTAssertTrue(HotkeyHoldPolicy.shouldHideOnRelease(
            wasVisibleAtPress: true, pressDuration: 2.0
        ))
    }
}
