// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

final class UsagePaceTests: XCTestCase {
    private let day: TimeInterval = 86400

    func testNilResetHidesPace() {
        XCTAssertNil(UsagePace.fraction(now: Date(), resetsAt: nil, totalDays: 30))
    }

    func testNonPositiveWindowHidesPace() {
        let now = Date()
        XCTAssertNil(UsagePace.fraction(now: now, resetsAt: now, totalDays: 0))
        XCTAssertNil(UsagePace.fraction(now: now, resetsAt: now, totalDays: -7))
    }

    func testThreeDaysIntoThirty() {
        let reset = Date(timeIntervalSince1970: 1_000_000)
        let now = reset.addingTimeInterval(-27 * day)

        XCTAssertEqual(UsagePace.fraction(now: now, resetsAt: reset, totalDays: 30) ?? -1, 0.1, accuracy: 1e-9)
    }

    func testMiddayDoesNotAdvanceStep() {
        let reset = Date(timeIntervalSince1970: 1_000_000)
        let now = reset.addingTimeInterval(-27 * day + 12 * 3600)

        XCTAssertEqual(UsagePace.fraction(now: now, resetsAt: reset, totalDays: 30) ?? -1, 0.1, accuracy: 1e-9)
    }

    func testWindowStartIsZero() {
        let reset = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(
            UsagePace.fraction(now: reset.addingTimeInterval(-7 * day), resetsAt: reset, totalDays: 7) ?? -1,
            0, accuracy: 1e-9)
    }

    func testFullWeekIsOne() {
        let reset = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(
            UsagePace.fraction(now: reset, resetsAt: reset, totalDays: 7) ?? -1,
            1, accuracy: 1e-9)
    }

    func testClampsOutsideWindow() {
        let reset = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(
            UsagePace.fraction(now: reset.addingTimeInterval(3 * day), resetsAt: reset, totalDays: 7) ?? -1,
            1, accuracy: 1e-9)
        XCTAssertEqual(
            UsagePace.fraction(now: reset.addingTimeInterval(-9 * day), resetsAt: reset, totalDays: 7) ?? -1,
            0, accuracy: 1e-9)
    }
}
