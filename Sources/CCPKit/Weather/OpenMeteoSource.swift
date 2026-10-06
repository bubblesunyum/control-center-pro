// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// What can go wrong fetching weather. Every failure — offline, error
/// status, unparsable body — reads as one case: the widget shows an inline
/// retry state, never a panel-blocking error.
public enum WeatherError: Sendable, Equatable, Error {
    case unavailable
}

// MARK: - Forecast

/// Where weather numbers come from.
///
/// The seam a test stands a fake in for: the real one needs a network round
/// trip, which a test cannot arrange.
public protocol WeatherSource: AnyObject, Sendable {
    func fetch(lat: Double, lon: Double) async throws -> WeatherSnapshot
}

/// The real one, against Open-Meteo's forecast endpoint — no API key.
public final class LiveOpenMeteoSource: WeatherSource {
    /// How many hourly points a snapshot carries.
    public static let hourlyPoints = 12
    /// How many daily points a snapshot carries.
    public static let dailyPoints = 3

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(lat: Double, lon: Double) async throws -> WeatherSnapshot {
        let data = try await Self.get(Self.forecastURL(lat: lat, lon: lon), via: session)
        return try Self.decodeSnapshot(from: data)
    }

    static func forecastURL(lat: Double, lon: Double) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        components.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(
                name: "current",
                value: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,uv_index"
            ),
            .init(name: "hourly", value: "temperature_2m,weather_code"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,uv_index_max"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "4"),
        ]
        // Static shape with numeric input — URLComponents only fails on a
        // broken host/path, which this one is not.
        return components.url!
    }

    /// Tolerantly decoded: every field is optional, so a response missing a
    /// section still yields the rest rather than failing the whole snapshot.
    /// Throws only when the body is not a forecast object at all, or when it
    /// holds nothing usable.
    static func decodeSnapshot(from data: Data, now: Date = Date()) throws -> WeatherSnapshot {
        let forecast: OpenMeteoForecast
        do {
            forecast = try JSONDecoder().decode(OpenMeteoForecast.self, from: data)
        } catch {
            throw WeatherError.unavailable
        }
        let snapshot = makeSnapshot(from: forecast, now: now)
        guard snapshot.condition != nil || !snapshot.hourly.isEmpty || !snapshot.daily.isEmpty else {
            throw WeatherError.unavailable
        }
        return snapshot
    }

    private static func makeSnapshot(from forecast: OpenMeteoForecast, now: Date) -> WeatherSnapshot {
        var snapshot = WeatherSnapshot()
        if let current = forecast.current {
            snapshot.tempC = current.temperature_2m
            snapshot.feelsLikeC = current.apparent_temperature
            if let code = current.weatherCode {
                snapshot.condition = .from(code: code)
            }
            snapshot.humidity = current.relative_humidity_2m.map { Int($0.rounded()) }
            snapshot.windKph = current.wind_speed_10m
            snapshot.uvIndex = current.uv_index
        }
        if let first = forecast.daily?.points().first {
            snapshot.highC = first.highC
            snapshot.lowC = first.lowC
        }
        snapshot.hourly = forecast.hourly?.next(hours: hourlyPoints, from: now, offsetSeconds: forecast.utc_offset_seconds ?? 0) ?? []
        snapshot.daily = Array((forecast.daily?.points() ?? []).prefix(dailyPoints))
        return snapshot
    }

    private static func get(_ url: URL, via session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("ControlCenterPro", forHTTPHeaderField: "User-Agent")
        let body: Data
        let response: URLResponse
        do {
            (body, response) = try await session.data(for: request)
        } catch {
            // Cancellation is the panel shutting mid-fetch, not an outage.
            if error is CancellationError { throw error }
            throw WeatherError.unavailable
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw WeatherError.unavailable
        }
        return body
    }
}

// MARK: - Forecast wire format

/// Top-level forecast object. Field names match the API; everything is
/// optional so partial responses still decode.
struct OpenMeteoForecast: Decodable {
    var current: OpenMeteoCurrent?
    var hourly: OpenMeteoHourly?
    var daily: OpenMeteoDaily?
    var utc_offset_seconds: Double?
}

struct OpenMeteoCurrent: Decodable {
    var temperature_2m: Double?
    var relative_humidity_2m: Double?
    var apparent_temperature: Double?
    var weather_code: Double?
    var wind_speed_10m: Double?
    var uv_index: Double?

    /// WMO codes are ints on the wire; Double tolerates either shape.
    var weatherCode: Int? { weather_code.map(Int.init) }
}

struct OpenMeteoHourly: Decodable {
    var time: [String]?
    var temperature_2m: [Double]?
    var weather_code: [Double]?

    /// The next `hours` points at or after `now`. Hourly times are wall
    /// clock in the location's zone, so they are shifted by the response's
    /// UTC offset before comparing — the device and the location may be in
    /// different zones.
    func next(hours: Int, from now: Date, offsetSeconds: Double) -> [WeatherHourPoint] {
        guard let times = time, let temps = temperature_2m, let codes = weather_code else { return [] }
        let wallClock = Self.makeWallClock()
        let start = times.firstIndex(where: { Self.absolute($0, offsetSeconds: offsetSeconds, wallClock: wallClock) ?? .distantPast >= now })
            ?? 0
        return times.indices.dropFirst(start).prefix(hours).compactMap { i in
            guard i < temps.count, i < codes.count else { return nil }
            return WeatherHourPoint(tempC: temps[i], code: Int(codes[i]))
        }
    }

    private static func makeWallClock() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static func absolute(_ wall: String, offsetSeconds: Double, wallClock: DateFormatter) -> Date? {
        wallClock.date(from: wall)?.addingTimeInterval(-offsetSeconds)
    }
}

struct OpenMeteoDaily: Decodable {
    var time: [String]?
    var weather_code: [Double]?
    var temperature_2m_max: [Double]?
    var temperature_2m_min: [Double]?
    var uv_index_max: [Double]?

    func points() -> [WeatherDayPoint] {
        guard let count = time?.count, let max = temperature_2m_max, let min = temperature_2m_min,
              let codes = weather_code
        else { return [] }
        return (0..<count).compactMap { i in
            guard i < max.count, i < min.count, i < codes.count else { return nil }
            let uv = uv_index_max.flatMap { i < $0.count ? $0[i] : nil }
            return WeatherDayPoint(highC: max[i], lowC: min[i], code: Int(codes[i]), uvMax: uv)
        }
    }
}
