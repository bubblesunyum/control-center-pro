// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// What the weather widget draws at one instant.
///
/// Plain values; the widget decides how to draw them. Nothing here is
/// persisted — every panel open refetches.
public struct WeatherSnapshot: Sendable, Equatable {
    public var tempC: Double?
    public var feelsLikeC: Double?
    public var condition: WeatherCondition?
    public var highC: Double?
    public var lowC: Double?
    public var humidity: Int? // percent
    public var windKph: Double?
    public var uvIndex: Double?
    public var hourly: [WeatherHourPoint] // next hours, oldest first
    public var daily: [WeatherDayPoint] // today first

    public init(
        tempC: Double? = nil,
        feelsLikeC: Double? = nil,
        condition: WeatherCondition? = nil,
        highC: Double? = nil,
        lowC: Double? = nil,
        humidity: Int? = nil,
        windKph: Double? = nil,
        uvIndex: Double? = nil,
        hourly: [WeatherHourPoint] = [],
        daily: [WeatherDayPoint] = []
    ) {
        self.tempC = tempC
        self.feelsLikeC = feelsLikeC
        self.condition = condition
        self.highC = highC
        self.lowC = lowC
        self.humidity = humidity
        self.windKph = windKph
        self.uvIndex = uvIndex
        self.hourly = hourly
        self.daily = daily
    }

    public static let empty = WeatherSnapshot()
}

/// One hourly point: temperature and WMO weather code.
public struct WeatherHourPoint: Sendable, Equatable {
    public var tempC: Double
    public var code: Int

    public init(tempC: Double, code: Int) {
        self.tempC = tempC
        self.code = code
    }

    public var condition: WeatherCondition { .from(code: code) }
}

/// One daily point: max/min, WMO weather code, max UV.
public struct WeatherDayPoint: Sendable, Equatable {
    public var highC: Double
    public var lowC: Double
    public var code: Int
    public var uvMax: Double?

    public init(highC: Double, lowC: Double, code: Int, uvMax: Double? = nil) {
        self.highC = highC
        self.lowC = lowC
        self.code = code
        self.uvMax = uvMax
    }

    public var condition: WeatherCondition { .from(code: code) }
}

/// A WMO weather code with its display label and SF Symbol.
public struct WeatherCondition: Sendable, Equatable {
    public var code: Int
    public var label: String
    public var symbolName: String

    public init(code: Int, label: String, symbolName: String) {
        self.code = code
        self.label = label
        self.symbolName = symbolName
    }

    /// Maps a WMO weather code to its display form. Codes outside the table
    /// (unused numbers, future additions) still render as a cloud rather
    /// than blanking the widget.
    public static func from(code: Int) -> WeatherCondition {
        let (label, symbolName): (String, String)
        switch code {
        case 0: (label, symbolName) = ("Clear", "sun.max")
        case 1: (label, symbolName) = ("Mainly clear", "sun.max")
        case 2: (label, symbolName) = ("Partly cloudy", "cloud.sun")
        case 3: (label, symbolName) = ("Overcast", "cloud")
        case 45: (label, symbolName) = ("Fog", "cloud.fog")
        case 48: (label, symbolName) = ("Rime fog", "cloud.fog")
        case 51: (label, symbolName) = ("Light drizzle", "cloud.drizzle")
        case 53: (label, symbolName) = ("Drizzle", "cloud.drizzle")
        case 55: (label, symbolName) = ("Dense drizzle", "cloud.drizzle")
        case 56, 57: (label, symbolName) = ("Freezing drizzle", "cloud.sleet")
        case 61: (label, symbolName) = ("Light rain", "cloud.rain")
        case 63: (label, symbolName) = ("Rain", "cloud.rain")
        case 65: (label, symbolName) = ("Heavy rain", "cloud.heavyrain")
        case 66, 67: (label, symbolName) = ("Freezing rain", "cloud.sleet")
        case 71: (label, symbolName) = ("Light snow", "cloud.snow")
        case 73: (label, symbolName) = ("Snow", "cloud.snow")
        case 75: (label, symbolName) = ("Heavy snow", "cloud.snow")
        case 77: (label, symbolName) = ("Snow grains", "cloud.snow")
        case 80: (label, symbolName) = ("Light showers", "cloud.rain")
        case 81: (label, symbolName) = ("Showers", "cloud.heavyrain")
        case 82: (label, symbolName) = ("Violent showers", "cloud.heavyrain")
        case 85: (label, symbolName) = ("Snow showers", "cloud.snow")
        case 86: (label, symbolName) = ("Heavy snow showers", "cloud.snow")
        case 95: (label, symbolName) = ("Thunderstorm", "cloud.bolt")
        case 96, 99: (label, symbolName) = ("Thunderstorm with hail", "cloud.hail")
        default: (label, symbolName) = ("Unknown", "cloud")
        }
        return WeatherCondition(code: code, label: label, symbolName: symbolName)
    }
}

/// UV severity band for a UV index value.
///
/// EPA bands: below 3 low, 3–5 moderate, 6–7 high, 8–10 very high, 11+
/// extreme. Boundary values belong to the higher band (3.0 is moderate).
public enum UVBand: String, Sendable, Equatable, CaseIterable {
    case low
    case moderate
    case high
    case veryHigh
    case extreme

    public init(uvIndex: Double) {
        guard uvIndex.isFinite, uvIndex >= 3 else {
            self = .low
            return
        }
        if uvIndex < 6 {
            self = .moderate
        } else if uvIndex < 8 {
            self = .high
        } else if uvIndex < 11 {
            self = .veryHigh
        } else {
            self = .extreme
        }
    }

    public var label: String {
        switch self {
        case .low: "Low"
        case .moderate: "Moderate"
        case .high: "High"
        case .veryHigh: "Very High"
        case .extreme: "Extreme"
        }
    }
}
