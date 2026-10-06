// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import Observation

/// Celsius or Fahrenheit. The unit owns its formatting so every readout
/// agrees: Open-Meteo speaks Celsius, and the conversion lives here.
public enum WeatherUnit: String, Codable, Sendable, CaseIterable {
    case celsius
    case fahrenheit

    public var symbol: String {
        switch self {
        case .celsius: "°C"
        case .fahrenheit: "°F"
        }
    }

    /// Whole degrees, converted when needed.
    public func format(celsius value: Double) -> String {
        let shown = self == .celsius ? value : value * 9 / 5 + 32
        return "\(Int(shown.rounded()))\(symbol)"
    }
}

/// What weather.json holds. The stored keys are the on-disk contract:
/// renaming a property renames its key and strands every existing file.
public struct WeatherStoredSettings: Codable, Sendable, Equatable {
    public var manualCity: String?
    public var latitude: Double?
    public var longitude: Double?
    public var unit: WeatherUnit

    public init(
        manualCity: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        unit: WeatherUnit = .celsius
    ) {
        self.manualCity = manualCity
        self.latitude = latitude
        self.longitude = longitude
        self.unit = unit
    }

    private enum CodingKeys: String, CodingKey {
        case manualCity
        case latitude
        case longitude
        case unit
    }
}

/// Where the weather is for and in what unit, surviving relaunch in
/// weather.json. Nil city and nil coordinates mean auto-locate: the widget
/// locates the user itself rather than reading a pinned place.
@MainActor
@Observable
public final class WeatherSettings {
    public static let shared = WeatherSettings()

    public var manualCity: String? { didSet { persist() } }
    public var latitude: Double? { didSet { persist() } }
    public var longitude: Double? { didSet { persist() } }
    public var unit: WeatherUnit { didSet { persist() } }

    /// Nothing pinned: the widget auto-locates.
    public var isAutoLocated: Bool {
        (manualCity?.isEmpty ?? true) && latitude == nil && longitude == nil
    }

    @ObservationIgnored private let store: JSONFileStore<WeatherStoredSettings>

    public init(store: JSONFileStore<WeatherStoredSettings> = JSONFileStore(
        filename: "weather.json",
        default: WeatherStoredSettings()
    )) {
        // A file that fails to decode reads as the default and stays on disk
        // untouched — unknown bytes are shown as empty state, never replaced.
        let stored = store.load()
        self.store = store
        self.manualCity = stored.manualCity
        self.latitude = stored.latitude
        self.longitude = stored.longitude
        self.unit = stored.unit
    }

    /// Forget the pinned place and go back to auto-locate.
    public func resetToAutoLocate() {
        manualCity = nil
        latitude = nil
        longitude = nil
    }

    private func persist() {
        try? store.save(WeatherStoredSettings(
            manualCity: manualCity,
            latitude: latitude,
            longitude: longitude,
            unit: unit
        ))
    }
}
