// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
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
                        WeatherLoadedView(snapshot: snapshot, unit: weatherDisplayUnit, placeName: placeName)
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
                    WeatherLoadedView(snapshot: snapshot, unit: weatherDisplayUnit, placeName: placeName)
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
            // One VoiceOver label for action plus readout: a bare action
            // label would shadow the temperature inside the button.
            let heroLabel = [
                "Open Weather app",
                snapshot.tempC.map { "temperature \(unit.format(celsius: $0))" },
                snapshot.condition?.label
            ].compactMap { $0 }.joined(separator: ", ")
            Button {
                let fallback = URL(fileURLWithPath: "/System/Applications/Weather.app")
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Weather") ?? fallback
                NSWorkspace.shared.open(url)
            } label: {
                HStack(alignment: .top, spacing: Space.one) {
                    VStack(alignment: .leading, spacing: Space.quarter) {
                        if let tempC = snapshot.tempC {
                            Text(unit.format(celsius: tempC))
                                .font(.largeTitle.weight(.semibold))
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(heroLabel)
            .help("Open in Weather")
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
            if uvDayWindow(pastHours: snapshot.pastHours, hours: snapshot.hourly).points.filter({ $0.uvIndex != nil }).count >= 2 {
                Divider()
                WeatherUVDayCurve(pastHours: snapshot.pastHours, hours: snapshot.hourly)
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

// MARK: - UV day curve

/// Shared drawing constants for the UV day curve: the Sparkline stroke/fill
/// language, and the one x-inset both the curve endpoints and the tick
/// labels honor so each label centers on the point it names.
private enum WeatherUVStyle {
    static let xInset: CGFloat = Space.half
    static let lineWidth: CGFloat = 1.5
    static let fillOpacity: Double = 0.16
}

/// UV through the day in the Mac Weather manner: a 12-point window straddling
/// now, drawn as a curve over the hourly uvIndex values with a gradient
/// fill, a now-marker dot, and a forward-looking peak callout. The call site hides it unless
/// the window holds at least two UV values, leaving the legacy UV row alone.
private struct WeatherUVDayCurve: View {
    let pastHours: [WeatherHourPoint]
    let hours: [WeatherHourPoint]

    /// Pointer position over the graph, fed by the hover tracker; nil when
    /// the pointer is off the graph. The hovered hour derives from it.
    @State private var hoverLocation: CGPoint?

    /// The drawn slice plus where now sits in it — one source for the curve,
    /// ticks, hover, and callouts.
    private var window: (points: [WeatherHourPoint], nowPosition: Int) {
        uvDayWindow(pastHours: pastHours, hours: hours)
    }

    private var values: [Double] { window.points.map { $0.uvIndex ?? 0 } }
    /// The peak looks forward only: the max from now on, never a past high.
    private var forwardValues: [Double] { Array(window.points.dropFirst(window.nowPosition)).map { $0.uvIndex ?? 0 } }
    private var peak: Double { forwardValues.max() ?? 0 }
    private var ceiling: Double { max(peak, 1) }
    private var peakIndex: Int { window.nowPosition + (forwardValues.firstIndex(of: peak) ?? 0) }
    private var curveColor: Color { UVBand(uvIndex: peak).dotColor }

    /// Sparse x ticks over the window: edges, thirds, and always now. Thirds
    /// adjacent to Now are dropped so tick labels never collide with the Now
    /// label — steady state yields [0, 3, Now, last]. Deduped so short lists
    /// never repeat an index.
    private var tickIndices: [Int] {
        let last = window.points.count - 1
        guard last > 0 else { return [] }
        let thirds = [0, last / 3, (last * 2) / 3, last]
        let clear = thirds.filter { abs($0 - window.nowPosition) > 1 }
        return Array(Set(clear + [min(window.nowPosition, last)])).sorted()
    }

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: Space.quarter) {
            Text("Peak \(Int(peak.rounded())) at \(hourLabel(at: peakIndex, from: now))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                let plot = uvDayPlot(values: values, ceiling: ceiling, size: proxy.size)
                let hoverIndex = hoverLocation.flatMap { uvHoverIndex(x: $0.x, width: proxy.size.width, count: window.points.count) }
                ZStack {
                    // Sizes the stack to the graph so the hover tracker
                    // behind it covers exactly the plotted area.
                    Color.clear
                    uvDayPath(plot: plot, bottomY: proxy.size.height, closed: true)
                        .fill(
                            LinearGradient(
                                colors: [curveColor.opacity(WeatherUVStyle.fillOpacity), curveColor.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    uvDayPath(plot: plot, bottomY: proxy.size.height, closed: false)
                        .stroke(curveColor, style: StrokeStyle(lineWidth: WeatherUVStyle.lineWidth, lineCap: .round, lineJoin: .round))
                    if window.nowPosition < plot.count {
                        Circle()
                            .fill(Color.primary)
                            .frame(width: Space.one, height: Space.one)
                            .position(plot[window.nowPosition])
                    }
                    // Pointer-only readout: VoiceOver already carries these
                    // values through the combined label and peak callout.
                    if plot.count >= 2, let hoverIndex {
                        WeatherUVHoverCallout(
                            point: plot[hoverIndex],
                            graphSize: proxy.size,
                            color: curveColor,
                            hour: hourLabel(at: hoverIndex, from: now),
                            uv: "\(Int(values[hoverIndex].rounded()))"
                        )
                    }
                }
                .background(WeatherUVHoverViewRepresentable(location: $hoverLocation))
            }
            .frame(height: Layout.sparklineHeight)
            GeometryReader { proxy in
                // The y mapping is height-independent, so only x is read here.
                let plot = uvDayPlot(values: values, ceiling: ceiling, size: proxy.size)
                ZStack(alignment: .topLeading) {
                    Color.clear
                    ForEach(tickIndices, id: \.self) { index in
                        Text(hourLabel(at: index, from: now))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .position(x: min(max(plot[index].x, WeatherUVStyle.xInset), proxy.size.width - WeatherUVStyle.xInset), y: Space.one)
                    }
                }
            }
            .frame(height: Space.two)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("UV through the day, peak \(Int(peak.rounded())) at \(hourLabel(at: peakIndex, from: now))")
        // The window goes down with the graph intact, so mouseExited never
        // fires on hide — without this a reopen shows a phantom readout.
        .onPanelHidden { hoverLocation = nil }
    }

    /// An x label inside the window: the now position reads Now, stamped
    /// points format their own date like the strip, and dateless points fall
    /// back to the synthesized offset-from-now formula.
    private func hourLabel(at windowIndex: Int, from now: Date) -> String {
        if windowIndex == window.nowPosition { return "Now" }
        if let date = window.points[windowIndex].date { return date.formatted(.dateTime.hour()) }
        let offset = windowIndex - window.nowPosition
        return now.addingTimeInterval(Double(offset) * secondsPerHour).formatted(.dateTime.hour())
    }
}

/// The hover readout: rule, point, and value chip. Extracted so the curve
/// body reads as layers.
private struct WeatherUVHoverCallout: View {
    let point: CGPoint
    let graphSize: CGSize
    let color: Color
    let hour: String
    let uv: String

    var body: some View {
        Group {
            Path { path in
                path.move(to: CGPoint(x: point.x, y: 0))
                path.addLine(to: CGPoint(x: point.x, y: graphSize.height))
            }
            .stroke(Color.secondary, style: StrokeStyle(lineWidth: Stroke.hairline, lineCap: .round))
            Circle()
                .fill(color)
                .frame(width: Space.one + WeatherUVStyle.lineWidth, height: Space.one + WeatherUVStyle.lineWidth)
                .overlay(Circle().stroke(Color.primary, style: StrokeStyle(lineWidth: Stroke.hairline)))
                .position(point)
            // CountBadge's capsule language at medium weight.
            Text("\(hour) · UV \(uv)")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .padding(.horizontal, Space.half)
                .padding(.vertical, Space.quarter / 2)
                .background(Capsule().fill(Color.controlFill))
                .overlay(Capsule().strokeBorder(Color.cardStroke, lineWidth: Stroke.hairline))
                .foregroundStyle(.secondary)
                .position(x: chipX, y: chipY)
        }
        .accessibilityHidden(true)
    }

    /// Centered on the point like the tick labels, so edge hours stay on
    /// the graph; near the top the chip flips below the point instead of
    /// painting over the peak callout.
    private var chipX: CGFloat {
        min(max(point.x, WeatherUVStyle.xInset), graphSize.width - WeatherUVStyle.xInset)
    }

    private var chipY: CGFloat {
        point.y < Space.two ? point.y + Space.three : point.y - Space.three
    }
}

private struct WeatherHourStrip: View {
    let hours: [WeatherHourPoint]
    let unit: WeatherUnit

    var body: some View {
        let now = Date()
        HStack(alignment: .top, spacing: Space.half) {
            ForEach(Array(hours.prefix(WeatherLayout.hourCount).enumerated()), id: \.offset) { index, hour in
                VStack(spacing: Space.quarter) {
                    Text(hourLabel(index, from: now))
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
                .accessibilityLabel("\(hourLabel(index, from: now)): \(unit.format(celsius: hour.tempC))")
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
    /// How many hourly points the UV day curve draws: a 12-point window
    /// centered on now. Shorter lists plot what they have.
    static let uvDayCount = 12
}

/// Miles in a kilometre, for the imperial wind readout.
private let milesPerKilometer = 0.621371

private func displayWind(_ kph: Double) -> String {
    Locale.current.measurementSystem == .metric
        ? "\(Int(kph.rounded())) km/h" : "\(Int((kph * milesPerKilometer).rounded())) mph"
}

/// Fahrenheit-only while the unit switch is parked (ccp-ywe9); revert to
/// model.settings.unit when it returns.
private let weatherDisplayUnit: WeatherUnit = .fahrenheit

/// An hour on the panel clock. Shared by the hour strip and the UV curve so
/// their synthesized labels cannot drift apart.
private let secondsPerHour: TimeInterval = 3600

/// Synthesized hour labels for dateless (hand-built/preview) points: the
/// first reads Now and the rest count forward from it. Stamped points format
/// their own date instead — see the curve's hourLabel(at:from:).
private func hourLabel(_ index: Int, from now: Date) -> String {
    index == 0 ? "Now" : now.addingTimeInterval(Double(index) * secondsPerHour).formatted(.dateTime.hour())
}

/// The slice of the past+future timeline the UV graph draws: 12 points
/// centered on the now boundary, or everything when shorter — plus where now
/// sits inside the slice. One computation shared by the call-site gate and
/// the curve's window var, so both read the same points.
func uvDayWindow(pastHours: [WeatherHourPoint], hours: [WeatherHourPoint]) -> (points: [WeatherHourPoint], nowPosition: Int) {
    // No future data means no window: past alone would clamp "Now" onto a
    // stale point.
    guard !hours.isEmpty else { return ([], 0) }
    let combined = pastHours + hours
    let boundary = min(pastHours.count, combined.count)
    let span = WeatherLayout.uvDayCount
    let start = min(max(boundary - (span / 2), 0), max(0, combined.count - span))
    let end = min(start + span, combined.count)
    let points = Array(combined[start..<end])
    return (points, min(boundary - start, max(points.count - 1, 0)))
}

/// Plot points for the UV day curve: x is hour index across the width with
/// the shared dot-radius inset so end markers never clip; y is UV over
/// 0...ceiling inside Sparkline-style top and baseline insets, clamped to
/// 0...1 so peaks and zeros never push the stroke off the frame.
private func uvDayPlot(values: [Double], ceiling: Double, size: CGSize) -> [CGPoint] {
    guard values.count >= 2, ceiling > 0, size.width > 0, size.height > 0 else { return [] }
    let inset = WeatherUVStyle.xInset
    let span = max(size.width - (inset * 2), 0)
    let topY: CGFloat = 0.5
    let baselineY = max(topY, size.height - 0.5)
    let plotHeight = max(1, baselineY - topY)
    return values.enumerated().map { index, value in
        let x = inset + (span * CGFloat(index) / CGFloat(values.count - 1))
        let normalized = min(1, max(0, value / ceiling))
        let y = baselineY - (plotHeight * CGFloat(normalized))
        return CGPoint(x: x, y: y)
    }
}

/// The day-curve path through normalized plot points, dropped to the bottom
/// edge when filling under the curve.
private func uvDayPath(plot: [CGPoint], bottomY: CGFloat, closed: Bool) -> Path {
    Path { path in
        guard let first = plot.first else { return }
        path.move(to: first)
        for point in plot.dropFirst() { path.addLine(to: point) }
        if closed, let last = plot.last {
            path.addLine(to: CGPoint(x: last.x, y: bottomY))
            path.addLine(to: CGPoint(x: first.x, y: bottomY))
            path.closeSubpath()
        }
    }
}

/// The hovered hour: nearest plot index to the pointer x, if the pointer is
/// over the graph. Shares the plot's x-inset so the selection lands on the
/// point the eye sees.
private func uvHoverIndex(x: CGFloat, width: CGFloat, count: Int) -> Int? {
    guard count >= 2, width > 0 else { return nil }
    let inset = WeatherUVStyle.xInset
    let span = max(width - (inset * 2), 0)
    guard span > 0 else { return nil }
    let position = ((x - inset) / span) * CGFloat(count - 1)
    return min(max(Int(position.rounded()), 0), count - 1)
}

/// Reports pointer position over the UV graph: a tracking area covering the
/// view writes each move into a binding and clears it on exit. SwiftUI
/// offers hover callbacks but no hover position, so this is the AppKit
/// primitive for "which hour is the pointer over".
private struct WeatherUVHoverViewRepresentable: NSViewRepresentable {
    @Binding var location: CGPoint?

    func makeNSView(context: Context) -> WeatherUVHoverView {
        WeatherUVHoverView(location: $location)
    }

    func updateNSView(_ view: WeatherUVHoverView, context: Context) {
        view.location = $location
    }
}

/// Covers the UV graph and reports the pointer: moved positions select the
/// nearest hour, exit clears the selection. An NSView subclass rather than a
/// bare NSObject owner so the mouse methods genuinely override NSResponder
/// (which carries the UI actor in this SDK).
@MainActor
private final class WeatherUVHoverView: NSView {
    var location: Binding<CGPoint?>

    init(location: Binding<CGPoint?>) {
        self.location = location
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // The rect is the graph itself, and the panel never activates, so
        // the area tracks always rather than while active.
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        location.wrappedValue = convert(event.locationInWindow, from: nil)
    }

    override func mouseExited(with event: NSEvent) {
        location.wrappedValue = nil
    }
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
                WeatherHourPoint(tempC: 21, code: 2, uvIndex: 4),
                WeatherHourPoint(tempC: 21, code: 2, uvIndex: 5),
                WeatherHourPoint(tempC: 22, code: 1, uvIndex: 6),
                WeatherHourPoint(tempC: 22, code: 1, uvIndex: 7),
                WeatherHourPoint(tempC: 23, code: 0, uvIndex: 6),
                WeatherHourPoint(tempC: 22, code: 1, uvIndex: 5),
                WeatherHourPoint(tempC: 21, code: 2, uvIndex: 4),
                WeatherHourPoint(tempC: 20, code: 2, uvIndex: 2),
            ],
            pastHours: [
                WeatherHourPoint(tempC: 16, code: 3, uvIndex: 0),
                WeatherHourPoint(tempC: 15, code: 3, uvIndex: 0),
                WeatherHourPoint(tempC: 15, code: 2, uvIndex: 0),
                WeatherHourPoint(tempC: 16, code: 2, uvIndex: 1),
                WeatherHourPoint(tempC: 18, code: 1, uvIndex: 2),
                WeatherHourPoint(tempC: 20, code: 2, uvIndex: 3),
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
