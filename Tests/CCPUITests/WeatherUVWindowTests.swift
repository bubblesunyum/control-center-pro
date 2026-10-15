// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import XCTest
@testable import CCPUI

@MainActor
final class WeatherUVWindowTests: XCTestCase {
    /// Distinct temps double as identities, so assertions read order as well
    /// as count.
    private func point(_ temp: Double) -> WeatherHourPoint {
        WeatherHourPoint(tempC: temp, code: 0, uvIndex: 1)
    }

    func testEmptyCombinedYieldsEmptyWindow() {
        let window = uvDayWindow(pastHours: [], hours: [], now: Date())
        XCTAssertEqual(window.points.count, 0)
        XCTAssertEqual(window.nowPosition, 0)
    }

    func testHoursEmptyYieldsNoWindow() {
        let window = uvDayWindow(pastHours: [point(0), point(1), point(2)], hours: [], now: Date())
        XCTAssertEqual(window.points.count, 0)
        XCTAssertEqual(window.nowPosition, 0)
    }

    func testSinglePointPlotsWhatExists() {
        let window = uvDayWindow(pastHours: [], hours: [point(7)], now: Date())
        XCTAssertEqual(window.points.map(\.tempC), [7])
        XCTAssertEqual(window.nowPosition, 0)
    }

    func testExactlyTwelveKeepsAllCentered() {
        let window = uvDayWindow(
            pastHours: (0..<6).map { point(Double($0)) },
            hours: (6..<12).map { point(Double($0)) },
            now: Date()
        )
        XCTAssertEqual(window.points.map(\.tempC), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        XCTAssertEqual(window.nowPosition, 6)
    }

    func testFullWindowCentersNow() {
        let window = uvDayWindow(
            pastHours: (0..<6).map { point(Double($0)) },
            hours: (6..<30).map { point(Double($0)) },
            now: Date()
        )
        XCTAssertEqual(window.points.map(\.tempC), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        XCTAssertEqual(window.nowPosition, 6)
    }

    func testEarlyMorningClampFillsForward() {
        let window = uvDayWindow(
            pastHours: [point(0), point(1)],
            hours: (2..<26).map { point(Double($0)) },
            now: Date()
        )
        XCTAssertEqual(window.points.map(\.tempC), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        XCTAssertEqual(window.nowPosition, 2)
    }
}
