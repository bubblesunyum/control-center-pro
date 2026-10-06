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
        XCTAssertEqual(snapshot.hourly.count, 12)
        XCTAssertEqual(snapshot.daily.count, 3)
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
        XCTAssertEqual(settings.unit, .celsius)
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
        XCTAssertEqual(settings.unit, .celsius)
        XCTAssertEqual(
            try String(contentsOf: store.url, encoding: .utf8),
            "{ this is not the weather }",
            "a read moves nothing aside — the evidence stays where it was"
        )
    }

    // MARK: - Recorded body

    /// Pinned just before the sample window, so hourly selection is exact
    /// rather than depending on the clock the test runs under.
    private static let sampleNow = Date(timeIntervalSince1970: 1_790_000_000)

    /// Recorded Open-Meteo forecast shape for one San Francisco noon. Hourly
    /// times are wall clock in the location's zone (UTC-7); `utc_offset_seconds`
    /// shifts them before comparing against `sampleNow`.
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
              "2026-10-06T12:00", "2026-10-06T13:00", "2026-10-06T14:00",
              "2026-10-06T15:00", "2026-10-06T16:00", "2026-10-06T17:00",
              "2026-10-06T18:00", "2026-10-06T19:00", "2026-10-06T20:00",
              "2026-10-06T21:00", "2026-10-06T22:00", "2026-10-06T23:00",
              "2026-10-07T00:00", "2026-10-07T01:00"
            ],
            "temperature_2m": [
              21.3, 21.8, 22.4, 22.9, 23.1, 22.6, 21.2, 19.8, 18.5, 17.6, 16.9, 16.4, 16.1, 15.8
            ],
            "weather_code": [
              2, 2, 1, 1, 0, 0, 1, 2, 2, 3, 3, 45, 45, 3
            ]
          },
          "daily": {
            "time": ["2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09"],
            "weather_code": [2, 3, 61, 0],
            "temperature_2m_max": [24.1, 22.8, 19.4, 23.0],
            "temperature_2m_min": [14.8, 14.1, 13.2, 13.9],
            "uv_index_max": [5.4, 4.8, 2.1, 5.9]
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
