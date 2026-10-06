// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import CoreLocation
import MapKit
import SwiftUI

/// Weather in a card: current conditions, UV, the next hours, the next days.
///
/// The data model is Kit's `WeatherAdapter` over a `WeatherSource`; this file
/// owns only what Kit deliberately doesn't — the one-shot CoreLocation fix,
/// manual city entry, and the card itself. A denied location degrades to
/// manual city entry, and a failed fetch degrades to an inline retry. Neither
/// ever blocks the panel.
@MainActor
public final class WeatherWidget: CCPWidget {
    public static let descriptor = WidgetDescriptor(
        id: "weather",
        title: "Weather",
        symbolName: "cloud.sun",
        size: .regular
    )

    private let model: WeatherPanelModel

    public init() {
        self.model = WeatherPanelModel(
            adapter: WeatherAdapter(),
            settings: .shared,
            location: CoreLocationWeatherProvider()
        )
    }

    /// Test seam: a widget backed by a fake source and location. Pass an
    /// adapter built with `WeatherAdapter(source:initialSnapshot:)`; the
    /// settings stay shared so manual-city persistence keeps working.
    public init(adapter: WeatherAdapter, locationProvider: any WeatherLocationProviding) {
        self.model = WeatherPanelModel(adapter: adapter, settings: .shared, location: locationProvider)
    }

    public func makeView() -> some View {
        WeatherContent(model: model)
    }

    public func activate() { model.activate() }
    public func deactivate() { model.deactivate() }
}

// MARK: - Location seam
//
// Kit's adapter takes coordinates and never touches CoreLocation, so the fix
// lives here: one-shot in production, a stub in tests and previews.

/// Where the card's coordinates come from.
@MainActor
public protocol WeatherLocationProviding: AnyObject {
    /// True once the user has denied location — the card offers manual entry.
    var authorizationDenied: Bool { get }
    /// One coordinate fix, or nil when denied, restricted, or timed out.
    func requestCoordinate() async -> CLLocationCoordinate2D?
    /// A typed city name resolved to coordinates, via geocoding.
    func coordinate(forCity city: String) async throws -> CLLocationCoordinate2D
}

// MARK: - Panel model

/// Resolves *where* the weather is for, then hands coordinates to Kit's
/// adapter. A pinned city in settings wins; otherwise one location fix; a
/// denial lands on manual entry.
@Observable
@MainActor
final class WeatherPanelModel {
    enum Place: Equatable {
        case unknown
        case located(latitude: Double, longitude: Double, name: String)
        case needsCity
    }

    var place: Place = .unknown
    var cityError: String?

    let adapter: WeatherAdapter
    let settings: WeatherSettings
    let location: any WeatherLocationProviding

    @ObservationIgnored
    private var task: Task<Void, Never>?

    init(adapter: WeatherAdapter, settings: WeatherSettings, location: any WeatherLocationProviding) {
        self.adapter = adapter
        self.settings = settings
        self.location = location
    }

    func activate() {
        task?.cancel()
        task = Task { await self.resolve() }
    }

    func deactivate() {
        task?.cancel()
        task = nil
        adapter.deactivate()
    }

    func refresh() {
        cityError = nil
        task?.cancel()
        task = Task { await self.resolve() }
    }

    /// Pins a typed city: geocode it, persist the fix to settings, fetch.
    /// A city that doesn't resolve stays on the entry with an explanation.
    func useCity(_ city: String) async {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cityError = nil
        do {
            let coordinate = try await location.coordinate(forCity: trimmed)
            settings.manualCity = trimmed
            settings.latitude = coordinate.latitude
            settings.longitude = coordinate.longitude
            place = .located(latitude: coordinate.latitude, longitude: coordinate.longitude, name: trimmed)
            await adapter.load(lat: coordinate.latitude, lon: coordinate.longitude)
        } catch is CancellationError {
            return
        } catch {
            cityError = "Couldn't find that city."
        }
    }

    /// Forgets the pinned city and goes back to the fix.
    func useCurrentLocation() {
        settings.resetToAutoLocate()
        refresh()
    }

    private func resolve() async {
        // A pinned fix wins — no location prompt, no waiting. The one-shot
        // fetch updates the card now; activate keeps the 15-minute loop
        // alive (a no-op when it already is).
        if let lat = settings.latitude, let lon = settings.longitude {
            place = .located(latitude: lat, longitude: lon, name: settings.manualCity ?? "Saved Location")
            await adapter.load(lat: lat, lon: lon)
            adapter.activate(lat: lat, lon: lon)
            return
        }
        // A fix already on screen still stands — re-fetch it rather than
        // re-prompting location on every refresh.
        if case .located(let lat, let lon, _) = place {
            await adapter.load(lat: lat, lon: lon)
            adapter.activate(lat: lat, lon: lon)
            return
        }
        if Task.isCancelled { return }
        if let fix = await location.requestCoordinate() {
            if Task.isCancelled { return }
            place = .located(latitude: fix.latitude, longitude: fix.longitude, name: "Current Location")
            adapter.activate(lat: fix.latitude, lon: fix.longitude)
        } else {
            if Task.isCancelled { return }
            place = .needsCity
        }
    }
}

// MARK: - Content

private struct WeatherContent: View {
    @Bindable var model: WeatherPanelModel
    @State private var cityDraft = ""

    var body: some View {
        WidgetCard(WeatherWidget.descriptor, accessory: {
            HeaderIconButton(systemImage: "arrow.clockwise", label: "Refresh weather") {
                model.refresh()
            }
        }) {
            // A snapshot on screen stays on screen: background refreshes must
            // not flash the card back to a spinner.
            if let snapshot = model.adapter.snapshot {
                if model.place == .needsCity {
                    VStack(alignment: .leading, spacing: Space.one) {
                        WeatherLoadedView(snapshot: snapshot, unit: model.settings.unit, placeName: placeName)
                        Divider()
                        Button {
                            model.useCurrentLocation()
                        } label: {
                            Label("Use Current Location", systemImage: "location")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Use current location")
                        WeatherManualEntryView(cityDraft: $cityDraft, error: model.cityError) {
                            Task { await model.useCity(cityDraft) }
                        }
                    }
                } else {
                    WeatherLoadedView(snapshot: snapshot, unit: model.settings.unit, placeName: placeName)
                }
            } else if model.place == .needsCity {
                WeatherManualEntryView(cityDraft: $cityDraft, error: model.cityError) {
                    Task { await model.useCity(cityDraft) }
                }
            } else if model.adapter.state == .failed {
                WeatherFailedView {
                    model.refresh()
                }
            } else {
                WeatherLoadingView()
            }
        }
    }

    private var placeName: String? {
        if case .located(_, _, let name) = model.place { return name }
        return model.settings.manualCity
    }
}

private struct WeatherLoadingView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
            .fill(Color.controlFill)
            .frame(minHeight: Layout.toolIconSize)
            .overlay(
                Text("Measuring…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            )
            .accessibilityLabel("Loading weather")
    }
}

private struct WeatherManualEntryView: View {
    @Binding var cityDraft: String
    let error: String?
    let submit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.one) {
            Label("Location unavailable", systemImage: "location.slash")
                .font(.headline)
            Text("Enter a city to see its weather.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: Space.half) {
                TextField("City", text: $cityDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("City")
                    .onSubmit(submit)
                Button("Use", action: submit)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Use this city")
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct WeatherFailedView: View {
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.one) {
            Label("Couldn't load weather", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("Check your connection and try again.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Retry loading weather")
        }
        .accessibilityElement(children: .contain)
    }
}

private struct WeatherLoadedView: View {
    let snapshot: WeatherSnapshot
    let unit: WeatherUnit
    let placeName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.one) {
            if let placeName {
                Text(placeName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: Space.one) {
                VStack(alignment: .leading, spacing: Space.quarter) {
                    if let tempC = snapshot.tempC {
                        Text(unit.format(celsius: tempC))
                            .font(.largeTitle.weight(.semibold))
                            .accessibilityLabel("Temperature \(unit.format(celsius: tempC))")
                    }
                    if let condition = snapshot.condition {
                        Text(condition.label)
                            .font(.subheadline)
                    }
                }
                Spacer(minLength: Space.half)
                Image(systemName: snapshot.condition?.symbolName ?? "cloud")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            if snapshot.highC != nil || snapshot.lowC != nil {
                Text("H:\(snapshot.highC.map { unit.format(celsius: $0) } ?? "–")  L:\(snapshot.lowC.map { unit.format(celsius: $0) } ?? "–")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("High \(snapshot.highC.map { unit.format(celsius: $0) } ?? "unknown"), low \(snapshot.lowC.map { unit.format(celsius: $0) } ?? "unknown")")
            }
            if let humidity = snapshot.humidity {
                detailRow("Humidity", value: "\(humidity)%")
                    .accessibilityLabel("Humidity \(humidity) percent")
            }
            if let windKph = snapshot.windKph {
                detailRow("Wind", value: displayWind(windKph))
            }
            if let uvIndex = snapshot.uvIndex {
                Divider()
                WeatherUVRow(uvIndex: uvIndex)
            }
            if !snapshot.hourly.isEmpty {
                Divider()
                WeatherHourStrip(hours: snapshot.hourly, unit: unit)
            }
            if !snapshot.daily.isEmpty {
                Divider()
                WeatherDayRows(days: snapshot.daily, unit: unit)
            }
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(spacing: Space.half) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: Space.half)
            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
    }
}

private struct WeatherUVRow: View {
    let uvIndex: Double

    private var band: UVBand { UVBand(uvIndex: uvIndex) }

    var body: some View {
        HStack(spacing: Space.half) {
            Circle()
                .fill(band.dotColor)
                .frame(width: Space.one, height: Space.one)
                .accessibilityHidden(true)
            Text("UV \(Int(uvIndex.rounded()))")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Text(band.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("UV index \(Int(uvIndex.rounded())), \(band.label)")
    }
}

/// The dot's whole job is the number beside it, so it borrows the platform's
/// green-to-purple ramp — system colours, never literals.
private extension UVBand {
    var dotColor: Color {
        switch self {
        case .low: .green
        case .moderate: .yellow
        case .high: .orange
        case .veryHigh: .red
        case .extreme: .purple
        }
    }
}

private struct WeatherHourStrip: View {
    let hours: [WeatherHourPoint]
    let unit: WeatherUnit

    var body: some View {
        // Kit's points carry no timestamps — the source selects the next
        // hours from now, so the first reads Now and the rest count forward.
        let now = Date()
        HStack(alignment: .top, spacing: Space.half) {
            ForEach(Array(hours.prefix(WeatherLayout.hourCount).enumerated()), id: \.offset) { index, hour in
                let date = now.addingTimeInterval(Double(index) * 3600)
                VStack(spacing: Space.quarter) {
                    Text(index == 0 ? "Now" : date.formatted(.dateTime.hour()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: hour.condition.symbolName)
                        .font(.caption)
                    Text(unit.format(celsius: hour.tempC))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(index == 0 ? "Now" : date.formatted(.dateTime.hour())): \(unit.format(celsius: hour.tempC))")
            }
        }
    }
}

private struct WeatherDayRows: View {
    let days: [WeatherDayPoint]
    let unit: WeatherUnit

    var body: some View {
        // Today first, then forward — the source orders them that way.
        let today = Calendar.current.startOfDay(for: Date())
        VStack(alignment: .leading, spacing: Space.half) {
            ForEach(Array(days.prefix(WeatherLayout.dayCount).enumerated()), id: \.offset) { index, day in
                let date = Calendar.current.date(byAdding: .day, value: index, to: today) ?? today
                HStack(spacing: Space.half) {
                    Text(index == 0 ? "Today" : date.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: day.condition.symbolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let uvMax = day.uvMax {
                        Text("UV \(Int(uvMax.rounded()))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    Text(unit.format(celsius: day.highC))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                    Text(unit.format(celsius: day.lowC))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(date.formatted(.dateTime.weekday(.wide))): high \(unit.format(celsius: day.highC)), low \(unit.format(celsius: day.lowC))\(day.uvMax.map { ", UV \(Int($0.rounded()))" } ?? "")")
            }
        }
    }
}

private enum WeatherLayout {
    static let hourCount = 8
    static let dayCount = 3
}

/// Miles in a kilometre, for the imperial wind readout.
private let milesPerKilometer = 0.621371

private func displayWind(_ kph: Double) -> String {
    Locale.current.measurementSystem == .metric
        ? "\(Int(kph.rounded())) km/h" : "\(Int((kph * milesPerKilometer).rounded())) mph"
}

// MARK: - Location

/// One-shot fix: asks once, reports one coordinate, then stops. A denial (or
/// a fix that never arrives) resolves nil so the card degrades to manual city
/// entry instead of hanging on a spinner.
@MainActor
private final class CoreLocationWeatherProvider: NSObject, WeatherLocationProviding, CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private var pending: CheckedContinuation<CLLocationCoordinate2D?, Never>?
    private var requestGeneration = 0

    override init() {
        self.manager = CLLocationManager()
        super.init()
        manager.delegate = self
        // Weather needs a neighbourhood, not a doorstep — coarse is faster
        // and worth saying so at the prompt.
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    var authorizationDenied: Bool {
        [.denied, .restricted].contains(manager.authorizationStatus)
    }

    func requestCoordinate() async -> CLLocationCoordinate2D? {
        let status = manager.authorizationStatus
        if status == .denied || status == .restricted { return nil }
        if status == .notDetermined { manager.requestWhenInUseAuthorization() }
        return await withCheckedContinuation { continuation in
            pending?.resume(returning: nil)
            pending = continuation
            // A reopen arms a fresh timer; only the latest request's timer
            // may resolve the current continuation.
            requestGeneration += 1
            let generation = requestGeneration
            // Already determined: ask now. Undetermined: the delegate asks
            // once the prompt answers.
            if manager.authorizationStatus != .notDetermined {
                manager.requestLocation()
            }
            // An ignored prompt or a silent fix must not hang the card.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.requestTimeout) { @MainActor [weak self] in
                guard let self, self.requestGeneration == generation else { return }
                self.finish(with: nil)
            }
        }
    }

    func coordinate(forCity city: String) async throws -> CLLocationCoordinate2D {
        // CLGeocoder is deprecated on this target; MapKit's request is its
        // replacement and returns no items when the address doesn't resolve.
        let items: [MKMapItem]
        if let request = MKGeocodingRequest(addressString: city) {
            items = try await request.mapItems
        } else {
            items = []
        }
        guard let item = items.first else {
            throw CityLookupError.notFound
        }
        let coordinate = item.location.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else {
            throw CityLookupError.notFound
        }
        return coordinate
    }

    // MARK: CLLocationManagerDelegate

    // Nonisolated: the delegate protocol is not actor-aware, so these hop
    // back to the main actor with Sendable values only.
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        Task { @MainActor [weak self] in
            self?.finish(with: coordinate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.finish(with: nil)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.authorizationChanged(to: status)
        }
    }

    private func authorizationChanged(to status: CLAuthorizationStatus) {
        switch status {
        case .denied, .restricted:
            finish(with: nil)
        case .authorizedWhenInUse, .authorizedAlways:
            if pending != nil { manager.requestLocation() }
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    private func finish(with coordinate: CLLocationCoordinate2D?) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(returning: coordinate)
    }

    private static let requestTimeout: TimeInterval = 12
}

private enum CityLookupError: Error {
    case notFound
}

// MARK: - Previews

private final class PreviewWeatherSource: WeatherSource, Sendable {
    let snapshot: WeatherSnapshot

    init(snapshot: WeatherSnapshot) {
        self.snapshot = snapshot
    }

    func fetch(lat: Double, lon: Double) async throws -> WeatherSnapshot {
        snapshot
    }
}

@MainActor
private final class PreviewDeniedLocation: WeatherLocationProviding {
    var authorizationDenied: Bool { true }

    func requestCoordinate() async -> CLLocationCoordinate2D? { nil }

    func coordinate(forCity city: String) async throws -> CLLocationCoordinate2D {
        throw CityLookupError.notFound
    }
}

private extension WeatherSnapshot {
    static var previewSample: WeatherSnapshot {
        WeatherSnapshot(
            tempC: 21,
            condition: .from(code: 2),
            highC: 22,
            lowC: 14,
            humidity: 58,
            windKph: 14,
            uvIndex: 5,
            hourly: [
                WeatherHourPoint(tempC: 21, code: 2),
                WeatherHourPoint(tempC: 21, code: 2),
                WeatherHourPoint(tempC: 22, code: 1),
                WeatherHourPoint(tempC: 22, code: 1),
                WeatherHourPoint(tempC: 23, code: 0),
                WeatherHourPoint(tempC: 22, code: 1),
                WeatherHourPoint(tempC: 21, code: 2),
                WeatherHourPoint(tempC: 20, code: 2),
            ],
            daily: [
                WeatherDayPoint(highC: 22, lowC: 14, code: 2, uvMax: 5),
                WeatherDayPoint(highC: 24, lowC: 15, code: 0, uvMax: 7),
                WeatherDayPoint(highC: 19, lowC: 12, code: 61, uvMax: 2),
            ]
        )
    }
}

#if DEBUG
#Preview("Weather — loaded") {
    let adapter = WeatherAdapter(
        source: PreviewWeatherSource(snapshot: .previewSample),
        initialSnapshot: .previewSample
    )
    WeatherContent(model: WeatherPanelModel(
        adapter: adapter,
        settings: .shared,
        location: PreviewDeniedLocation()
    ))
}

#Preview("Weather — no location") {
    let model = WeatherPanelModel(
        adapter: WeatherAdapter(source: PreviewWeatherSource(snapshot: .previewSample)),
        settings: .shared,
        location: PreviewDeniedLocation()
    )
    model.place = .needsCity
    return WeatherContent(model: model)
}
#endif
