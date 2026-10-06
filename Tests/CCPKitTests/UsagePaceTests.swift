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
    }

    func testNonPositiveWindowHidesPace() {
        let now = Date()
        XCTAssertNil(UsagePace.fraction(now: now, resetsAt: now, totalHours: 0))
        XCTAssertNil(UsagePace.fraction(now: now, resetsAt: now, totalHours: -168))
    }

    func testThreeDaysIntoThirty() {
        let reset = Date(timeIntervalSince1970: 1_000_000)
        let now = reset.addingTimeInterval(-27 * day)

        XCTAssertEqual(UsagePace.fraction(now: now, resetsAt: reset, totalHours: 720) ?? -1, 0.1, accuracy: 1e-9)
    }

    func testFlooredPaceHoldsWithinTheHour() {
        let reset = Date(timeIntervalSince1970: 1_000_000)
        let now = reset.addingTimeInterval(-27 * day + 30 * 60)

        // A mid-hour glance still reads the current hour.
        XCTAssertEqual(UsagePace.fraction(now: now, resetsAt: reset, totalHours: 720) ?? -1, 0.1, accuracy: 1e-9)
    }

    func testWindowStartIsZero() {
        let reset = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(
            UsagePace.fraction(now: reset.addingTimeInterval(-168 * hour), resetsAt: reset, totalHours: 168) ?? -1,
            0, accuracy: 1e-9)
    }

    func testFullWeekIsOne() {
        let reset = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(
            UsagePace.fraction(now: reset, resetsAt: reset, totalHours: 168) ?? -1,
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

    // MARK: - Daily pace

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testDailyNilWithoutReset() {
        XCTAssertNil(UsagePace.dailyFraction(now: Date(), resetsAt: nil, totalDays: 30, calendar: utcCalendar))
    }

    func testDailyNonPositiveWindowHidesPace() {
        let now = Date()
        XCTAssertNil(UsagePace.dailyFraction(now: now, resetsAt: now, totalDays: 0, calendar: utcCalendar))
        XCTAssertNil(UsagePace.dailyFraction(now: now, resetsAt: now, totalDays: -7, calendar: utcCalendar))
    }

    func testDailyFirstDayReadsOneWholeDay() {
        let calendar = utcCalendar
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!
        let reset = start.addingTimeInterval(30 * 86400)
        let now = start.addingTimeInterval(60)

        XCTAssertEqual(
            UsagePace.dailyFraction(now: now, resetsAt: reset, totalDays: 30, calendar: calendar) ?? -1,
            1.0 / 30.0, accuracy: 1e-9)
    }

    func testDailyHoldsWithinTheDay() {
        let calendar = utcCalendar
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!
        let reset = start.addingTimeInterval(30 * 86400)
        let now = start.addingTimeInterval(14 * 3600)

        XCTAssertEqual(
            UsagePace.dailyFraction(now: now, resetsAt: reset, totalDays: 30, calendar: calendar) ?? -1,
            1.0 / 30.0, accuracy: 1e-9)
    }

    func testDailyStepsAtMidnight() {
        let calendar = utcCalendar
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!
        let reset = start.addingTimeInterval(30 * 86400)
        let now = calendar.startOfDay(for: start)
            .addingTimeInterval(86400 + 3600)

        XCTAssertEqual(
            UsagePace.dailyFraction(now: now, resetsAt: reset, totalDays: 30, calendar: calendar) ?? -1,
            2.0 / 30.0, accuracy: 1e-9)
    }

    func testDailyWeeklyFirstDay() {
        let calendar = utcCalendar
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!
        let reset = start.addingTimeInterval(7 * 86400)
        let now = start.addingTimeInterval(60)

        XCTAssertEqual(
            UsagePace.dailyFraction(now: now, resetsAt: reset, totalDays: 7, calendar: calendar) ?? -1,
            1.0 / 7.0, accuracy: 1e-9)
    }

    func testDailyClampsOutsideWindow() {
        let calendar = utcCalendar
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!
        let reset = start.addingTimeInterval(7 * 86400)

        XCTAssertEqual(
            UsagePace.dailyFraction(
                now: start.addingTimeInterval(-3600), resetsAt: reset, totalDays: 7, calendar: calendar) ?? -1,
            0, accuracy: 1e-9)
        XCTAssertEqual(
            UsagePace.dailyFraction(
                now: reset.addingTimeInterval(3 * 86400), resetsAt: reset, totalDays: 7, calendar: calendar) ?? -1,
            1, accuracy: 1e-9)
    }
}
