// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

/// The weather Kit bead's seam is `WeatherSource` (class-bound): the fake
/// below decodes a recorded Open-Meteo body through the live source's own
/// `decodeSnapshot`, so the mapping is tested, not the socket. UV edges cover
/// `UVBand`, WMO spot checks cover `WeatherCondition.from(code:)`, C/F
/// covers `WeatherUnit`, and persistence covers `WeatherSettings` over a temp
/// `JSONFileStore`.
@MainActor
final class WeatherAdapterTests: XCTestCase {
    // MARK: - Recorded sample

    func testDecodesRecordedOpenMeteoSample() throws {
        let snapshot = try LiveOpenMeteoSource.decodeSnapshot(from: Data(Self.sampleJSON.utf8), now: Self.sampleNow)

        XCTAssertEqual(snapshot.tempC, 21.3)
        XCTAssertEqual(snapshot.humidity, 62)
        XCTAssertEqual(snapshot.condition, WeatherCondition(code: 2, label: "Partly cloudy", symbolName: "cloud.sun"))
        XCTAssertEqual(snapshot.uvIndex, 5.4)
        XCTAssertEqual(snapshot.windKph, 14.5)
        XCTAssertEqual(snapshot.highC, 24.1)
        XCTAssertEqual(snapshot.lowC, 14.8)
        XCTAssertEqual(snapshot.hourly.count, 24)
        XCTAssertEqual(snapshot.daily.count, 6)
    }

    func testHourlyPointsCarryPerHourUV() throws {
        let snapshot = try LiveOpenMeteoSource.decodeSnapshot(from: Data(Self.sampleJSON.utf8), now: Self.sampleNow)

        XCTAssertEqual(snapshot.hourly.map(\.uvIndex), [
            5.4, 5.1, 4.4, 3.5, 2.4, 1.3, 0.4, 0.0, 0.0, 0.0, 0.0, 0.0,
            0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.1, 0.8, 2.0, 3.2, 4.2,
        ])
    }

    func testHourlyPointsTolerateMissingOrShortUV() throws {
        let missingJSON = """
            {
              "utc_offset_seconds": -25200,
              "hourly": {
                "time": ["2026-10-06T12:00", "2026-10-06T13:00"],
                "temperature_2m": [21.3, 21.8],
                "weather_code": [2, 1]
              }
            }
            """
        let missing = try LiveOpenMeteoSource.decodeSnapshot(from: Data(missingJSON.utf8), now: Self.sampleNow)
        XCTAssertEqual(missing.hourly.count, 2)
        XCTAssertNil(missing.hourly[0].uvIndex)
        XCTAssertNil(missing.hourly[1].uvIndex)

        let short = OpenMeteoHourly(
            time: ["2026-10-06T12:00", "2026-10-06T13:00", "2026-10-06T14:00"],
            temperature_2m: [21.3, 21.8, 22.4],
            weather_code: [2, 2, 1],
            uv_index: [5.4]
        )
        let points = short.next(hours: 3, from: Self.sampleNow, offsetSeconds: -25200)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].uvIndex, 5.4)
        XCTAssertNil(points[1].uvIndex)
        XCTAssertNil(points[2].uvIndex)
    }

    func testNextHoursAreStampedWithAbsoluteDates() throws {
        let snapshot = try LiveOpenMeteoSource.decodeSnapshot(from: Data(Self.sampleJSON.utf8), now: Self.sampleNow)

        XCTAssertEqual(snapshot.hourly.count, 24)
        let dates = snapshot.hourly.compactMap(\.date)
        XCTAssertEqual(dates.count, 24)
        // Noon wall clock in UTC-7 is 19:00 UTC.
        XCTAssertEqual(dates.first, Date(timeIntervalSince1970: 1_791_313_200))
        XCTAssertEqual(dates.last?.timeIntervalSince(dates.first ?? .distantPast), 23 * 3600)
    }

    func testPastHoursAreOldestFirstWithAbsoluteDates() throws {
        let snapshot = try LiveOpenMeteoSource.decodeSnapshot(from: Data(Self.sampleJSON.utf8), now: Self.sampleNow)

        XCTAssertEqual(snapshot.pastHours.map(\.tempC), [15.2, 15.0, 15.8, 17.1, 18.6, 20.1])
        let dates = snapshot.pastHours.compactMap(\.date)
        XCTAssertEqual(dates.count, 6)
        // 06:00 wall clock in UTC-7 is 13:00 UTC.
        XCTAssertEqual(dates.first, Date(timeIntervalSince1970: 1_791_291_600))
        for (earlier, later) in zip(dates, dates.dropFirst()) {
            XCTAssertEqual(later.timeIntervalSince(earlier), 3600)
        }
        let nextDates = snapshot.hourly.compactMap(\.date)
        XCTAssertEqual(nextDates.first?.timeIntervalSince(dates.last ?? .distantPast), 3600)
    }

    func testPriorClampsToAvailableHours() {
        let morning = OpenMeteoHourly(
            time: ["2026-10-06T10:00", "2026-10-06T11:00", "2026-10-06T12:00"],
            temperature_2m: [18.6, 20.1, 21.3],
            weather_code: [1, 2, 2],
            uv_index: [2.1, 3.8, 5.4]
        )
        let points = morning.prior(hours: 16, from: Self.sampleNow, offsetSeconds: -25200)
        XCTAssertEqual(points.map(\.tempC), [18.6, 20.1])
        XCTAssertEqual(points.compactMap(\.date), [
            Date(timeIntervalSince1970: 1_791_306_000),
            Date(timeIntervalSince1970: 1_791_309_600),
        ])
    }

    func testAllPastBodyYieldsEmptyNextAndTailPrior() {
        let stale = OpenMeteoHourly(
            time: ["2026-10-06T06:00", "2026-10-06T07:00", "2026-10-06T08:00"],
            temperature_2m: [15.2, 15.0, 15.8],
            weather_code: [3, 3, 2],
            uv_index: [0.0, 0.0, 0.1]
        )
        // sampleNow sits hours after the last entry: everything is past, so
        // next() is empty instead of a stale head and prior() holds the tail.
        XCTAssertEqual(stale.next(hours: 24, from: Self.sampleNow, offsetSeconds: -25200).count, 0)
        let tail = stale.prior(hours: 16, from: Self.sampleNow, offsetSeconds: -25200)
        XCTAssertEqual(tail.map(\.tempC), [15.2, 15.0, 15.8])
        XCTAssertEqual(tail.compactMap(\.date).count, 3)
    }

    func testFakeSourceServesTheRecordedSample() async throws {
        let source = FakeWeatherSource(snapshot: try LiveOpenMeteoSource.decodeSnapshot(
            from: Data(Self.sampleJSON.utf8),
            now: Self.sampleNow
        ))
        let adapter = WeatherAdapter(source: source)

        await adapter.load(lat: 37.77, lon: -122.41)

        XCTAssertEqual(adapter.snapshot?.tempC, 21.3)
        XCTAssertEqual(adapter.snapshot?.condition?.label, "Partly cloudy")
        XCTAssertEqual(adapter.state, .loaded)
        XCTAssertEqual(source.lastLat, 37.77)
        XCTAssertEqual(source.lastLon, -122.41)
    }

    func testUnreadableSampleIsUnavailableRatherThanGuessed() {
        XCTAssertThrowsError(
            try LiveOpenMeteoSource.decodeSnapshot(from: Data("{ this is not weather }".utf8))
        ) { error in
            XCTAssertEqual(error as? WeatherError, .unavailable)
        }
    }

    func testAdapterFailureShowsFailed() async {
        let adapter = WeatherAdapter(source: FakeWeatherSource(error: WeatherError.unavailable))

        await adapter.load(lat: 37.77, lon: -122.41)

        XCTAssertEqual(adapter.state, .failed)
        XCTAssertEqual(adapter.lastError, .unavailable)
        XCTAssertNil(adapter.snapshot)
    }

    // MARK: - UV bands

    func testUVBandEdges() {
        let edges: [(Double, UVBand)] = [
            (0, .low), (2.9, .low),
            (3, .moderate), (5.9, .moderate),
            (6, .high), (7.9, .high),
            (8, .veryHigh), (10.9, .veryHigh),
            (11, .extreme), (13.2, .extreme),
        ]
        for (index, expected) in edges {
            XCTAssertEqual(
                UVBand(uvIndex: index), expected,
                "uv \(index) should sit in \(expected)"
            )
        }
    }

    func testNonFiniteUVReadsAsLow() {
        XCTAssertEqual(UVBand(uvIndex: .nan), .low)
        XCTAssertEqual(UVBand(uvIndex: -1), .low)
    }

    // MARK: - WMO codes

    func testWMOCodeSpotChecks() {
        let codes: [(Int, String, String)] = [
            (0, "Clear", "sun.max"),
            (2, "Partly cloudy", "cloud.sun"),
            (3, "Overcast", "cloud"),
            (45, "Fog", "cloud.fog"),
            (61, "Light rain", "cloud.rain"),
            (71, "Light snow", "cloud.snow"),
            (95, "Thunderstorm", "cloud.bolt"),
        ]
        for (code, label, symbol) in codes {
            XCTAssertEqual(
                WeatherCondition.from(code: code),
                WeatherCondition(code: code, label: label, symbolName: symbol),
                "wmo code \(code) should map to \(label)"
            )
        }
    }

    func testUnknownWMOCodeStillRenders() {
        XCTAssertEqual(
            WeatherCondition.from(code: 999),
            WeatherCondition(code: 999, label: "Unknown", symbolName: "cloud")
        )
    }

    // MARK: - C/F formatting

    func testUnitFormatsWholeDegrees() {
        XCTAssertEqual(WeatherUnit.celsius.format(celsius: 21.3), "21°C")
        XCTAssertEqual(WeatherUnit.fahrenheit.format(celsius: 21.3), "70°F")
        XCTAssertEqual(WeatherUnit.celsius.format(celsius: -3.6), "-4°C")
    }

    // MARK: - Settings persistence

    func testDefaultsToAutoLocate() {
        let settings = WeatherSettings(
            store: temporaryStore(default: WeatherStoredSettings(), filename: "weather.json")
        )

        XCTAssertTrue(settings.isAutoLocated)
        XCTAssertEqual(settings.unit, .localeDefault)
        XCTAssertEqual(WeatherStoredSettings().unit, .localeDefault)
    }

    func testManualCityAndUnitSurviveRelaunch() {
        let store = temporaryStore(default: WeatherStoredSettings(), filename: "weather.json")
        let first = WeatherSettings(store: store)
        first.manualCity = "Lisbon"
        first.latitude = 38.72
        first.longitude = -9.14
        first.unit = .fahrenheit

        // A second settings object over the same directory: what a relaunch reads.
        let relaunched = WeatherSettings(store: JSONFileStore(
            filename: "weather.json",
            default: WeatherStoredSettings(),
            in: store.url.deletingLastPathComponent()
        ))

        XCTAssertEqual(relaunched.manualCity, "Lisbon")
        XCTAssertEqual(relaunched.latitude, 38.72)
        XCTAssertEqual(relaunched.longitude, -9.14)
        XCTAssertEqual(relaunched.unit, .fahrenheit)
        XCTAssertFalse(relaunched.isAutoLocated)
    }

    func testResetReturnsToAutoLocate() {
        let settings = WeatherSettings(
            store: temporaryStore(default: WeatherStoredSettings(), filename: "weather.json")
        )
        settings.manualCity = "Lisbon"
        settings.latitude = 38.72

        settings.resetToAutoLocate()

        XCTAssertTrue(settings.isAutoLocated)
    }

    func testUnreadableFileFallsBackToDefaultsAndStaysOnDisk() throws {
        let store = temporaryStore(default: WeatherStoredSettings(), filename: "weather.json")
        try write("{ this is not the weather }", forStore: store)

        let settings = WeatherSettings(store: store)

        XCTAssertTrue(settings.isAutoLocated)
        XCTAssertEqual(settings.unit, .localeDefault)
        XCTAssertEqual(
            try String(contentsOf: store.url, encoding: .utf8),
            "{ this is not the weather }",
            "a read moves nothing aside — the evidence stays where it was"
        )
    }

    // MARK: - Recorded body

    /// Pinned a minute before noon in the sample window, so next() starts at
    /// 12:00, prior() holds the six morning hours, and selection is exact
    /// rather than depending on the clock the test runs under.
    private static let sampleNow = Date(timeIntervalSince1970: 1_791_313_140)

    /// Recorded Open-Meteo forecast shape for one San Francisco noon, with
    /// six morning hours before it. Hourly times are wall clock in the
    /// location's zone (UTC-7); `utc_offset_seconds` shifts them before
    /// comparing against `sampleNow`.
    private static let sampleJSON = """
        {
          "latitude": 37.7749,
          "longitude": -122.4194,
          "utc_offset_seconds": -25200,
          "timezone": "America/Los_Angeles",
          "current": {
            "time": "2026-10-06T12:00",
            "temperature_2m": 21.3,
            "relative_humidity_2m": 62,
            "apparent_temperature": 22.1,
            "weather_code": 2,
            "wind_speed_10m": 14.5,
            "uv_index": 5.4
          },
          "hourly": {
            "time": [
              "2026-10-06T06:00", "2026-10-06T07:00", "2026-10-06T08:00",
              "2026-10-06T09:00", "2026-10-06T10:00", "2026-10-06T11:00",
              "2026-10-06T12:00", "2026-10-06T13:00", "2026-10-06T14:00",
              "2026-10-06T15:00", "2026-10-06T16:00", "2026-10-06T17:00",
              "2026-10-06T18:00", "2026-10-06T19:00", "2026-10-06T20:00",
              "2026-10-06T21:00", "2026-10-06T22:00", "2026-10-06T23:00",
              "2026-10-07T00:00", "2026-10-07T01:00", "2026-10-07T02:00",
              "2026-10-07T03:00", "2026-10-07T04:00", "2026-10-07T05:00",
              "2026-10-07T06:00", "2026-10-07T07:00", "2026-10-07T08:00",
              "2026-10-07T09:00", "2026-10-07T10:00", "2026-10-07T11:00",
              "2026-10-07T12:00", "2026-10-07T13:00"
            ],
            "temperature_2m": [
              15.2, 15.0, 15.8, 17.1, 18.6, 20.1,
              21.3, 21.8, 22.4, 22.9, 23.1, 22.6, 21.2, 19.8, 18.5, 17.6,
              16.9, 16.4, 16.1, 15.8, 15.5, 15.2, 14.9, 14.8, 15.0, 15.6,
              16.8, 18.2, 19.5, 20.6, 21.4, 21.9
            ],
            "weather_code": [
              3, 3, 2, 2, 1, 2,
              2, 2, 1, 1, 0, 0, 1, 2, 2, 3, 3, 45, 45, 3, 3, 3, 2, 2, 1, 1,
              0, 0, 1, 2, 2, 3
            ],
            "uv_index": [
              0.0, 0.0, 0.1, 0.6, 2.1, 3.8,
              5.4, 5.1, 4.4, 3.5, 2.4, 1.3, 0.4, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
              0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.1, 0.8, 2.0, 3.2, 4.2, 4.9, 5.2
            ]
          },
          "daily": {
            "time": ["2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09", "2026-10-10", "2026-10-11", "2026-10-12"],
            "weather_code": [2, 3, 61, 0, 1, 2, 1],
            "temperature_2m_max": [24.1, 22.8, 19.4, 23.0, 21.5, 20.0, 22.3],
            "temperature_2m_min": [14.8, 14.1, 13.2, 13.9, 13.5, 12.8, 13.1],
            "uv_index_max": [5.4, 4.8, 2.1, 5.9, 3.3, 4.1, 3.9]
          }
        }
        """
}

// MARK: - Fake

/// Stands in for the network: serves one canned result and remembers the
/// coordinates it was asked for, so the adapter's passthrough is tested.
private final class FakeWeatherSource: WeatherSource {
    var snapshot: WeatherSnapshot?
    var error: WeatherError?
    private(set) var lastLat: Double?
    private(set) var lastLon: Double?

    init(snapshot: WeatherSnapshot) {
        self.snapshot = snapshot
    }

    init(error: WeatherError) {
        self.error = error
    }

    func fetch(lat: Double, lon: Double) async throws -> WeatherSnapshot {
        lastLat = lat
        lastLon = lon
        if let error { throw error }
        return snapshot ?? .empty
    }
}
