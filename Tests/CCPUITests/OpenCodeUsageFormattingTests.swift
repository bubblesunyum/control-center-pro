// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPUI

@MainActor
final class OpenCodeUsageFormattingTests: XCTestCase {
    func testPercentUsesSingleDecimal() {
        XCTAssertEqual(OpenCodeUsageWidget.percentText(2), "2.0%")
        XCTAssertEqual(OpenCodeUsageWidget.percentText(12.34), "12.3%")
        XCTAssertEqual(OpenCodeUsageWidget.percentText(nil), "--")
    }

    func testResetBuckets() {
        let now = Date()
        XCTAssertEqual(
            OpenCodeUsageWidget.resetText(until: now.addingTimeInterval(45 * 60), now: now),
            "resets in 45m")
        XCTAssertEqual(
            OpenCodeUsageWidget.resetText(until: now.addingTimeInterval(3 * 3600 + 12 * 60), now: now),
            "resets in 3h 12m")
        XCTAssertEqual(
            OpenCodeUsageWidget.resetText(until: now.addingTimeInterval(4 * 86400 + 5 * 3600), now: now),
            "resets in 4d 5h")
    }

    func testResetHandlesMissingAndPast() {
        let now = Date()
        XCTAssertEqual(OpenCodeUsageWidget.resetText(until: nil, now: now), "--")
        XCTAssertEqual(
            OpenCodeUsageWidget.resetText(until: now.addingTimeInterval(-60), now: now),
            "resetting…")
        XCTAssertEqual(
            OpenCodeUsageWidget.resetText(until: now.addingTimeInterval(20), now: now),
            "resets in 1m")
    }
}
