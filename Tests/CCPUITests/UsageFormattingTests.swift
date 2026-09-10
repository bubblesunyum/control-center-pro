// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPUI

@MainActor
final class UsageFormattingTests: XCTestCase {
    func testPercentUsesSingleDecimal() {
        XCTAssertEqual(UsageWidget.percentText(2), "2.0%")
        XCTAssertEqual(UsageWidget.percentText(12.34), "12.3%")
        XCTAssertEqual(UsageWidget.percentText(nil), "--")
    }

    func testResetBuckets() {
        let now = Date()
        XCTAssertEqual(
            UsageWidget.resetText(until: now.addingTimeInterval(45 * 60), now: now),
            "45m")
        XCTAssertEqual(
            UsageWidget.resetText(until: now.addingTimeInterval(3 * 3600 + 12 * 60), now: now),
            "3h 12m")
        XCTAssertEqual(
            UsageWidget.resetText(until: now.addingTimeInterval(4 * 86400 + 5 * 3600), now: now),
            "4d 5h")
    }

    func testResetHandlesMissingAndPast() {
        let now = Date()
        XCTAssertEqual(UsageWidget.resetText(until: nil, now: now), "--")
        XCTAssertEqual(
            UsageWidget.resetText(until: now.addingTimeInterval(-60), now: now),
            "resetting…")
        XCTAssertEqual(
            UsageWidget.resetText(until: now.addingTimeInterval(20), now: now),
            "1m")
    }

    func testDescriptorIsGenericUsage() {
        XCTAssertEqual(UsageWidget.descriptor.id, "ai-usage")
        XCTAssertEqual(UsageWidget.descriptor.title, "AI Usage")
    }
}
