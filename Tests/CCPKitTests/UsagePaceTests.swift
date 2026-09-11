// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

final class UsagePaceTests: XCTestCase {
    private let day: TimeInterval = 86400
    private let hour: TimeInterval = 3600

    func testNilResetHidesPace() {
        XCTAssertNil(UsagePace.fraction(now: Date(), resetsAt: nil, totalHours: 720))
        XCTAssertNil(UsagePace.fraction(now: Date(), resetsAt: nil, totalHours: 720, ceilToNextHour: true))
    }

    func testNonPositiveWindowHidesPace() {
        let now = Date()
        XCTAssertNil(UsagePace.fraction(now: now, resetsAt: now, totalHours: 0))
        XCTAssertNil(UsagePace.fraction(now: now, resetsAt: now, totalHours: -168))
        XCTAssertNil(UsagePace.fraction(now: now, resetsAt: now, totalHours: 0, ceilToNextHour: true))
    }

    func testThreeDaysIntoThirty() {
        let reset = Date(timeIntervalSince1970: 1_000_000)
        let now = reset.addingTimeInterval(-27 * day)

        XCTAssertEqual(UsagePace.fraction(now: now, resetsAt: reset, totalHours: 720) ?? -1, 0.1, accuracy: 1e-9)
    }

    func testExactHourBoundaryCeilsToItself() {
        let reset = Date(timeIntervalSince1970: 1_000_000)
        let now = reset.addingTimeInterval(-27 * day)

        XCTAssertEqual(
            UsagePace.fraction(now: now, resetsAt: reset, totalHours: 720, ceilToNextHour: true) ?? -1,
            0.1, accuracy: 1e-9)
    }

    func testCeiledPaceAdvancesToNextHour() {
        let reset = Date(timeIntervalSince1970: 1_000_000)
        let now = reset.addingTimeInterval(-27 * day + 30 * 60)

        // Floored pace still reads the current hour; ceiled pace reads what
        // even spend allows by the hour's close.
        XCTAssertEqual(UsagePace.fraction(now: now, resetsAt: reset, totalHours: 720) ?? -1, 0.1, accuracy: 1e-9)
        XCTAssertEqual(
            UsagePace.fraction(now: now, resetsAt: reset, totalHours: 720, ceilToNextHour: true) ?? -1,
            73.0 / 720.0, accuracy: 1e-9)
    }

    func testWindowStartIsZero() {
        let reset = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(
            UsagePace.fraction(now: reset.addingTimeInterval(-168 * hour), resetsAt: reset, totalHours: 168) ?? -1,
            0, accuracy: 1e-9)
        XCTAssertEqual(
            UsagePace.fraction(now: reset.addingTimeInterval(-168 * hour), resetsAt: reset, totalHours: 168, ceilToNextHour: true) ?? -1,
            0, accuracy: 1e-9)
    }

    func testFullWeekIsOne() {
        let reset = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(
            UsagePace.fraction(now: reset, resetsAt: reset, totalHours: 168) ?? -1,
            1, accuracy: 1e-9)
        XCTAssertEqual(
            UsagePace.fraction(now: reset, resetsAt: reset, totalHours: 168, ceilToNextHour: true) ?? -1,
            1, accuracy: 1e-9)
    }

    func testClampsOutsideWindow() {
        let reset = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(
            UsagePace.fraction(now: reset.addingTimeInterval(3 * day), resetsAt: reset, totalHours: 168) ?? -1,
            1, accuracy: 1e-9)
        XCTAssertEqual(
            UsagePace.fraction(now: reset.addingTimeInterval(-9 * day), resetsAt: reset, totalHours: 168) ?? -1,
            0, accuracy: 1e-9)
        // Ceil overshoots past the reset and still clamps; same before the start.
        XCTAssertEqual(
            UsagePace.fraction(now: reset.addingTimeInterval(30 * 60), resetsAt: reset, totalHours: 168, ceilToNextHour: true) ?? -1,
            1, accuracy: 1e-9)
        XCTAssertEqual(
            UsagePace.fraction(now: reset.addingTimeInterval(-169 * hour), resetsAt: reset, totalHours: 168, ceilToNextHour: true) ?? -1,
            0, accuracy: 1e-9)
    }

    func testTwoHoursIntoFive() {
        let reset = Date(timeIntervalSince1970: 1_000_000)
        let now = reset.addingTimeInterval(-3 * hour)

        XCTAssertEqual(UsagePace.fraction(now: now, resetsAt: reset, totalHours: 5) ?? -1, 0.4, accuracy: 1e-9)
    }

    func testMidHourDoesNotAdvanceStep() {
        let reset = Date(timeIntervalSince1970: 1_000_000)
        let now = reset.addingTimeInterval(-3 * hour + 30 * 60)

        XCTAssertEqual(UsagePace.fraction(now: now, resetsAt: reset, totalHours: 5) ?? -1, 0.4, accuracy: 1e-9)
    }

    func testHourlyPaceHidesWithoutReset() {
        XCTAssertNil(UsagePace.fraction(now: Date(), resetsAt: nil, totalHours: 5))
        XCTAssertNil(UsagePace.fraction(now: Date(), resetsAt: Date(), totalHours: 0))
    }
}
