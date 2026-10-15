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
    // Card type runs 2pt over the macOS semantic default (measured via
    // NSFont.preferredFont: caption 10, caption2 10, subheadline 11,
    // headline 13, largeTitle 26) and keeps scaling via the relative style.
    @ScaledMetric(relativeTo: .caption) private var captionPt: CGFloat = 12
    @Bindable var model: WeatherPanelModel
    @State private var cityDraft = ""

    var body: some View {
        WidgetCard(WeatherWidget.descriptor, accessory: {
            HStack(spacing: Space.one) {
                if let placeName {
                    Text(placeName)
                        .font(.system(size: captionPt))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HeaderIconButton(systemImage: "arrow.clockwise", label: "Refresh weather") {
                    model.refresh()
                }
            }
        }) {
            // A snapshot on screen stays on screen: background refreshes must
            // not flash the card back to a spinner.
            if let snapshot = model.adapter.snapshot {
                if model.place == .needsCity {
                    VStack(alignment: .leading, spacing: Space.two) {
                        WeatherLoadedView(snapshot: snapshot, unit: weatherDisplayUnit)
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
                    WeatherLoadedView(snapshot: snapshot, unit: weatherDisplayUnit)
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
    @ScaledMetric(relativeTo: .caption) private var captionPt: CGFloat = 12
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
            .fill(Color.controlFill)
            .frame(minHeight: Layout.toolIconSize)
            .overlay(
                Text("Measuring…")
                    .font(.system(size: captionPt))
                    .foregroundStyle(.secondary)
            )
            .accessibilityLabel("Loading weather")
    }
}

private struct WeatherManualEntryView: View {
    @ScaledMetric(relativeTo: .headline) private var headlinePt: CGFloat = 15
    @ScaledMetric(relativeTo: .caption) private var captionPt: CGFloat = 12
    @Binding var cityDraft: String
    let error: String?
    let submit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.two) {
            Label("Location unavailable", systemImage: "location.slash")
                .font(.system(size: headlinePt, weight: .bold))
            Text("Enter a city to see its weather.")
                .font(.system(size: captionPt))
                .foregroundStyle(.secondary)
            HStack(spacing: Space.one) {
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
                    .font(.system(size: captionPt))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct WeatherFailedView: View {
    @ScaledMetric(relativeTo: .headline) private var headlinePt: CGFloat = 15
    @ScaledMetric(relativeTo: .caption) private var captionPt: CGFloat = 12
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.two) {
            Label("Couldn't load weather", systemImage: "exclamationmark.triangle")
                .font(.system(size: headlinePt, weight: .bold))
            Text("Check your connection and try again.")
                .font(.system(size: captionPt))
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
    @ScaledMetric(relativeTo: .largeTitle) private var largeTitlePt: CGFloat = 28
    @ScaledMetric(relativeTo: .subheadline) private var subheadlinePt: CGFloat = 13
    let snapshot: WeatherSnapshot
    let unit: WeatherUnit

    var body: some View {
        VStack(alignment: .leading, spacing: Space.two) {
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
                HStack(alignment: .top, spacing: Space.two) {
                    VStack(alignment: .leading, spacing: Space.half) {
                        if let tempC = snapshot.tempC {
                            Text(degreeOnly(tempC, in: unit))
                                .font(.system(size: largeTitlePt, weight: .semibold))
                        }
                    }
                    Spacer(minLength: Space.one)
                    HStack(alignment: .center, spacing: Space.one) {
                        if let condition = snapshot.condition {
                            Text(condition.label)
                                .font(.system(size: subheadlinePt))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .multilineTextAlignment(.trailing)
                        }
                        Image(systemName: snapshot.condition?.symbolName ?? "cloud")
                            .font(.title)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(heroLabel)
            .help("Open in Weather")
            if snapshot.highC != nil || snapshot.lowC != nil || snapshot.humidity != nil || snapshot.windKph != nil {
                HStack(alignment: .firstTextBaseline, spacing: Space.one) {
                    if snapshot.highC != nil || snapshot.lowC != nil {
                        HStack(spacing: Space.one) {
                            HStack(spacing: Space.half) {
                                Text("H:")
                                    .foregroundStyle(.secondary)
                                if let highC = snapshot.highC {
                                    (Text(degreeNumber(highC, in: unit)).foregroundStyle(.primary) + Text("°").foregroundStyle(.secondary))
                                        .monospacedDigit()
                                } else {
                                    Text("–")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: Space.half) {
                                Text("L:")
                                    .foregroundStyle(.secondary)
                                if let lowC = snapshot.lowC {
                                    (Text(degreeNumber(lowC, in: unit)).foregroundStyle(.primary) + Text("°").foregroundStyle(.secondary))
                                        .monospacedDigit()
                                } else {
                                    Text("–")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.system(size: subheadlinePt))
                        .lineLimit(1)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("High \(snapshot.highC.map { unit.format(celsius: $0) } ?? "unknown"), low \(snapshot.lowC.map { unit.format(celsius: $0) } ?? "unknown")")
                    }
                    if snapshot.humidity != nil || snapshot.windKph != nil {
                        if snapshot.highC != nil || snapshot.lowC != nil {
                            Spacer()
                        }
                        HStack(spacing: Space.two) {
                            if let humidity = snapshot.humidity {
                                WeatherStatItem(
                                    icon: "drop.fill",
                                    text: "\(humidity)%",
                                    label: "Humidity \(humidity) percent"
                                )
                            }
                            if let windKph = snapshot.windKph {
                                WeatherStatItem(
                                    icon: "wind",
                                    text: displayWind(windKph),
                                    label: "Wind \(displayWind(windKph))"
                                )
                            }
                        }
                    }
                }
            }
            WeatherUVSection(uvIndex: snapshot.uvIndex, pastHours: snapshot.pastHours, hours: snapshot.hourly)
            if snapshot.hourly.count > 1 {
                Divider()
                WeatherHourStrip(hours: snapshot.hourly, unit: unit)
            }
            if snapshot.daily.count > 1 {
                Divider()
                WeatherDayRows(days: snapshot.daily, unit: unit)
            }
        }
    }
}

private struct WeatherStatItem: View {
    @ScaledMetric(relativeTo: .caption) private var captionPt: CGFloat = 12
    let icon: String
    let text: String
    let label: String

    var body: some View {
        HStack(spacing: Space.one) {
            Image(systemName: icon)
                .font(.system(size: captionPt))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: captionPt, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

private struct WeatherUVRow: View {
    @ScaledMetric(relativeTo: .caption) private var captionPt: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var caption2Pt: CGFloat = 12
    let uvIndex: Double
    let peakText: String?

    private var band: UVBand { UVBand(uvIndex: uvIndex) }

    var body: some View {
        HStack(spacing: Space.one) {
            Circle()
                .fill(band.dotColor)
                .frame(width: Space.one, height: Space.one)
                .accessibilityHidden(true)
            Text("UV \(Int(uvIndex.rounded()))")
                .font(.system(size: captionPt, weight: .semibold))
                .monospacedDigit()
            Text(band.label)
                .font(.system(size: captionPt))
                .foregroundStyle(.secondary)
            Spacer(minLength: Space.one)
            if let peakText {
                Text(peakText)
                    .font(.system(size: caption2Pt, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([
            "UV index \(Int(uvIndex.rounded())), \(band.label)",
            peakText
        ].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Today's UV peak over the combined past+future timeline: when any point
/// carries a date, the max over points stamped today; otherwise the max over
/// everything (dateless preview points). The hour comes from the stamp when
/// present, else the synthesized offset from now, matching the curve ticks.
/// A stamped peak at or before now (or a dateless peak sitting before the
/// now boundary) reads "Peak was N at H"; an upcoming one "Peak N at H". The same-day filter is what rolls the callout over at
/// midnight, with the 15-minute refetch supplying the new day's hours.
private struct UVPeak {
    let value: Double
    let hourLabel: String
    let isPast: Bool

    var display: String {
        isPast
            ? "Peak was \(Int(value.rounded())) at \(hourLabel)"
            : "Peak \(Int(value.rounded())) at \(hourLabel)"
    }
}

private func uvSameDayPeak(
    pastHours: [WeatherHourPoint],
    hours: [WeatherHourPoint],
    now: Date
) -> UVPeak? {
    let combined = pastHours + hours
    guard !combined.isEmpty else { return nil }
    let boundary = min(pastHours.count, combined.count)
    var candidates = combined.enumerated().map { (index: $0.offset, point: $0.element) }
    if combined.contains(where: { $0.date != nil }) {
        let today = candidates.filter {
            guard let date = $0.point.date else { return false }
            return Calendar.current.isDate(date, inSameDayAs: now)
        }
        guard !today.isEmpty else { return nil }
        candidates = today
    }
    guard let best = candidates.max(by: { a, b in
        switch (a.point.uvIndex, b.point.uvIndex) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case (let x?, let y?): return x < y
        }
    }) else { return nil }
    guard let uvValue = best.point.uvIndex else { return nil }
    if let date = best.point.date {
        return UVPeak(
            value: uvValue,
            hourLabel: date.formatted(.dateTime.hour()),
            isPast: date <= now
        )
    }
    return UVPeak(
        value: uvValue,
        hourLabel: now.addingTimeInterval(Double(best.index - boundary) * secondsPerHour).formatted(.dateTime.hour()),
        isPast: best.index < boundary
    )
}

/// UV as one section: the row carries the same-day peak on its trailing edge
/// and the curve follows with no divider between them.
private struct WeatherUVSection: View {
    let uvIndex: Double?
    let pastHours: [WeatherHourPoint]
    let hours: [WeatherHourPoint]

    private func hasCurve(now: Date) -> Bool {
        uvDayWindow(pastHours: pastHours, hours: hours, now: now).points.filter { $0.uvIndex != nil }.count >= 2
    }

    var body: some View {
        let now = Date()
        let peak = uvSameDayPeak(pastHours: pastHours, hours: hours, now: now)
        let showsCurve = hasCurve(now: now)
        if uvIndex != nil || showsCurve {
            Divider()
        }
        if let uvIndex, showsCurve {
            VStack(alignment: .leading, spacing: Space.two) {
                WeatherUVRow(uvIndex: uvIndex, peakText: peak?.display)
                WeatherUVDayCurve(pastHours: pastHours, hours: hours, peak: peak, now: now)
            }
        } else if let uvIndex {
            WeatherUVRow(uvIndex: uvIndex, peakText: peak?.display)
        } else if showsCurve {
            WeatherUVDayCurve(pastHours: pastHours, hours: hours, peak: peak, now: now)
        }
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

/// Value-driven stroke hue for the UV day curve: a green→yellow→orange→
/// red→purple spread interpolated between stops, so neighbouring integers
/// stay unmistakable (UV3 reads yellow, UV6 reads orange). The UV row dot
/// keeps the discrete `UVBand` colour; only the graph uses this ramp.
private func uvCurveColor(_ uv: Double) -> Color {
    let stops: [(value: Double, color: NSColor)] = [
        (0, .systemGreen),
        (3, .systemYellow),
        (6, .systemOrange),
        (8, .systemRed),
        (11, .systemPurple),
    ]
    guard let first = stops.first, let last = stops.last else { return .clear }
    func mixed(_ lower: NSColor, _ upper: NSColor, t: Double) -> Color {
        let a = lower.usingColorSpace(.sRGB) ?? lower
        let b = upper.usingColorSpace(.sRGB) ?? upper
        return Color(nsColor: NSColor(
            calibratedRed: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
            alpha: 1
        ))
    }
    guard uv.isFinite else { return Color(nsColor: first.color) }
    if uv <= first.value {
        return Color(nsColor: first.color)
    }
    if uv >= last.value {
        return Color(nsColor: last.color)
    }
    for i in 1..<stops.count where uv <= stops[i].value {
        let lower = stops[i - 1]
        let upper = stops[i]
        let t = (uv - lower.value) / (upper.value - lower.value)
        return mixed(lower.color, upper.color, t: t)
    }
    return Color(nsColor: last.color)
}

// MARK: - UV day curve

/// Shared drawing constants for the UV day curve: the Sparkline stroke/fill
/// language, and the one x-inset both the curve endpoints and the tick
/// labels honor so each label centers on the point it names. The inset
/// matches the card's own padding (WidgetCard pads by Space.oneHalf), so
/// endpoints, tick labels, and the hover chip never paint into it; tick
/// centers clamp by the same half-label-width for the same reason.
private enum WeatherUVStyle {
    static let xInset: CGFloat = Space.oneHalf
    static let lineWidth: CGFloat = 1.5
    static let fillOpacity: Double = 0.16
    /// The drawn day window: today's 9AM–7PM hours (device zone, like the
    /// formatted labels). Ticks sit at 9/12/15/19 — the 18:00 slot sits
    /// ~25pt from 19:00 and collides with it when text scales.
    static let dayHours: ClosedRange<Int> = 9...19
    static let tickHours: [Int] = [9, 12, 15, 19]
    /// Hover chip width estimate: longest readout ("14 Uhr · UV 11") at the
    /// scaled caption2 advance, plus the capsule's horizontal padding.
    static let hoverEstimatedChars: Int = 16
    static let hoverCharAdvance: Double = 0.6
}

/// UV through the day in the Mac Weather manner: today's 9AM–7PM points
/// drawn as a curve over the hourly uvIndex values with a gradient
/// fill, a now-marker dot, and fixed 9/12/3/7 ticks. The same-day peak
/// callout lives in the UV row above the graph. The section hides the curve
/// unless the window holds at least two UV values.
private struct WeatherUVDayCurve: View {
    @ScaledMetric(relativeTo: .caption2) private var caption2Pt: CGFloat = 12
    let pastHours: [WeatherHourPoint]
    let hours: [WeatherHourPoint]
    let peak: UVPeak?
    let now: Date

    /// Pointer position over the graph, fed by the hover tracker; nil when
    /// the pointer is off the graph. The hovered hour derives from it.
    @State private var hoverLocation: CGPoint?

    /// The drawn slice plus where now sits in it — one source for the curve,
    /// ticks, hover, and callouts.
    private var window: (points: [WeatherHourPoint], nowPosition: Int) {
        uvDayWindow(pastHours: pastHours, hours: hours, now: now)
    }

    private var values: [Double] { window.points.map { $0.uvIndex ?? 0 } }
    /// The same-day peak, shared with the row callout above the graph: the
    /// ceiling and fill wash follow today's high, not the window tail. The
    /// stroke itself carries a stop per drawn point (see strokeGradient).
    private var peakValue: Double { peak?.value ?? 0 }
    private var ceiling: Double { max(peakValue, 1) }
    private var curveColor: Color { uvCurveColor(peakValue) }

    /// One gradient stop per drawn point in its own value-driven hue,
    /// spread evenly — the points are hourly, so even spacing is exact.
    private var strokeGradient: LinearGradient {
        let colors = values.map { uvCurveColor($0) }
        guard colors.count >= 2 else {
            return LinearGradient(colors: [curveColor, curveColor], startPoint: .leading, endPoint: .trailing)
        }
        let stops = colors.enumerated().map { index, color in
            Gradient.Stop(color: color, location: Double(index) / Double(colors.count - 1))
        }
        return LinearGradient(gradient: Gradient(stops: stops), startPoint: .leading, endPoint: .trailing)
    }

    /// The now dot shows only when now sits inside today's 9–19 window;
    /// outside it (morning, evening) the curve stands without a marker.
    /// Dateless fallback windows have no day to be inside of, so they keep
    /// the dot at the now boundary as before.
    private var showsNowDot: Bool {
        if window.points.contains(where: { $0.date != nil }) {
            guard let anchor = window.points.compactMap(\.date).first else { return false }
            let calendar = Calendar.current
            return calendar.isDate(now, inSameDayAs: anchor)
                && WeatherUVStyle.dayHours.contains(calendar.component(.hour, from: now))
        }
        return window.nowPosition < window.points.count
    }

    /// Fixed x ticks at 9AM/12PM/3PM/7PM wherever the window holds them.
    /// Dateless fallback windows (previews) keep the old edges-plus-now
    /// ticks so they still label something.
    private var tickIndices: [Int] {
        let calendar = Calendar.current
        let fixed = window.points.indices.filter { index in
            guard let date = window.points[index].date else { return false }
            return WeatherUVStyle.tickHours.contains(calendar.component(.hour, from: date))
        }
        if !fixed.isEmpty { return fixed }
        if window.points.contains(where: { $0.date != nil }) {
            // Stamped window with no 9/12/15/19 point (early/late hours):
            // label the drawn endpoints so the lane is never empty.
            guard window.points.count >= 2 else { return [] }
            return [0, window.points.count - 1]
        }
        let last = window.points.count - 1
        guard last > 0 else { return [] }
        let thirds = [0, last / 3, (last * 2) / 3, last]
        let clear = thirds.filter { abs($0 - window.nowPosition) > 1 }
        return Array(Set(clear + [min(window.nowPosition, last)])).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.half) {
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
                        .stroke(strokeGradient, style: StrokeStyle(lineWidth: WeatherUVStyle.lineWidth, lineCap: .round, lineJoin: .round))
                    if showsNowDot, window.nowPosition < plot.count {
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
                            hour: tickLabel(at: hoverIndex, from: now),
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
                        Text(tickLabel(at: index, from: now))
                            .font(.system(size: caption2Pt, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .position(x: min(max(plot[index].x, WeatherUVStyle.xInset), proxy.size.width - WeatherUVStyle.xInset), y: Space.one)
                    }
                }
            }
            .frame(height: max(Space.two, caption2Pt + Space.half))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(uvCurveLabel)
        // The window goes down with the graph intact, so mouseExited never
        // fires on hide — without this a reopen shows a phantom readout.
        .onPanelHidden { hoverLocation = nil }
    }

    /// VoiceOver mirrors the row's peak wording, so the graph never
    /// disagrees with the callout above it.
    private var uvCurveLabel: String {
        guard let peak else { return "UV through the day" }
        return "UV through the day, \(peak.display)"
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

    /// Tick labels prefer the stamp: fixed 9/12/3/7 ticks never read Now
    /// even when now sits exactly on the hour. Dateless fallbacks have no
    /// stamp, so they use the window label (with its Now) instead.
    private func tickLabel(at windowIndex: Int, from now: Date) -> String {
        if let date = window.points[windowIndex].date { return date.formatted(.dateTime.hour()) }
        return hourLabel(at: windowIndex, from: now)
    }
}

/// The hover readout: rule, point, and value chip. Extracted so the curve
/// body reads as layers.
private struct WeatherUVHoverCallout: View {
    @ScaledMetric(relativeTo: .caption2) private var caption2Pt: CGFloat = 12
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
                .font(.system(size: caption2Pt, weight: .medium))
                .monospacedDigit()
                .padding(.horizontal, Space.one)
                .padding(.vertical, Space.quarter)
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
        // The chip is wider than a tick label, so clamp by half its estimated
        // width (chars × advance + horizontal padding, scaled with caption2);
        // max() keeps the upper bound sane on narrow graphs.
        let halfChip = (CGFloat(WeatherUVStyle.hoverEstimatedChars) * caption2Pt * CGFloat(WeatherUVStyle.hoverCharAdvance) + Space.one * 2) / 2
        return min(max(point.x, halfChip), max(graphSize.width - halfChip, halfChip))
    }

    private var chipY: CGFloat {
        point.y < Space.two ? point.y + Space.three : point.y - Space.three
    }
}

private struct WeatherHourStrip: View {
    @ScaledMetric(relativeTo: .caption) private var captionPt: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var caption2Pt: CGFloat = 12
    let hours: [WeatherHourPoint]
    let unit: WeatherUnit

    var body: some View {
        let now = Date()
        let visibleHours = Array(hours.prefix(WeatherLayout.hourCount))
        HStack(alignment: .top, spacing: Space.one) {
            ForEach(Array(visibleHours.enumerated()), id: \.offset) { index, hour in
                let label = stripHourLabel(hour, at: index, from: now)
                VStack(spacing: Space.half) {
                    Text(label)
                        .font(.system(size: caption2Pt, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: hour.condition.symbolName)
                        .font(.system(size: captionPt))
                    Text(degreeOnly(hour.tempC, in: unit))
                        .font(.system(size: captionPt, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(label): \(unit.format(celsius: hour.tempC))")
            }
        }
    }
}

private struct WeatherDayRows: View {
    @ScaledMetric(relativeTo: .caption) private var captionPt: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var caption2Pt: CGFloat = 12
    let days: [WeatherDayPoint]
    let unit: WeatherUnit

    var body: some View {
        // Upcoming days only — today already reads in the hero and stats
        // above; the source orders them today-first.
        let today = Calendar.current.startOfDay(for: Date())
        VStack(alignment: .leading, spacing: Space.one) {
            ForEach(Array(days.dropFirst().prefix(WeatherLayout.dayCount).enumerated()), id: \.offset) { index, day in
                let date = Calendar.current.date(byAdding: .day, value: index + 1, to: today) ?? today
                HStack(spacing: Space.one) {
                    Text(date.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: captionPt))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: day.condition.symbolName)
                        .font(.system(size: captionPt))
                        .foregroundStyle(.secondary)
                    if let uvMax = day.uvMax {
                        Text("UV \(Int(uvMax.rounded()))")
                            .font(.system(size: caption2Pt, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    } else {
                        // Reserve the UV slot so high/low columns align across rows.
                        Text("UV 11")
                            .font(.system(size: caption2Pt, weight: .medium))
                            .monospacedDigit()
                            .hidden()
                            .accessibilityHidden(true)
                    }
                    Text(degreeOnly(day.highC, in: unit))
                        .font(.system(size: captionPt, weight: .medium))
                        .monospacedDigit()
                    Text(degreeOnly(day.lowC, in: unit))
                        .font(.system(size: captionPt))
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
    static let hourCount = 6
    static let dayCount = 5
    /// How many hourly points the UV day curve draws in dateless fallback:
    /// a 12-point window centered on now. Shorter lists plot what they have.
    /// Stamped timelines instead draw today's 9AM–7PM hours (see uvDayWindow).
    static let uvDayCount = 12
}

/// Miles in a kilometre, for the imperial wind readout.
private let milesPerKilometer = 0.621371

private func displayWind(_ kph: Double) -> String {
    Locale.current.measurementSystem == .metric
        ? "\(Int(kph.rounded())) km/h" : "\(Int((kph * milesPerKilometer).rounded())) mph"
}

/// Visible temperatures read in whole degrees with no unit letter; VoiceOver
/// keeps the full `WeatherUnit.format` strings. Kit's formatter is untouched.
private func degreeNumber(_ celsius: Double, in unit: WeatherUnit) -> String {
    let shown = unit == .celsius ? celsius : celsius * 9 / 5 + 32
    return "\(Int(shown.rounded()))"
}

private func degreeOnly(_ celsius: Double, in unit: WeatherUnit) -> String {
    "\(degreeNumber(celsius, in: unit))°"
}

/// Fahrenheit-only while the unit switch is parked (ccp-ywe9); revert to
/// model.settings.unit when it returns.
private let weatherDisplayUnit: WeatherUnit = .fahrenheit

/// An hour on the panel clock. Shared by the hour strip and the UV curve so
/// their synthesized labels cannot drift apart.
private let secondsPerHour: TimeInterval = 3600

/// A label on the hour strip: stamped points format their own date —
/// hours[0] is already the next whole hour since the Kit boundary is the
/// first time >= now — and dateless (hand-built/preview) points count
/// forward from now starting at +1h.
private func stripHourLabel(_ hour: WeatherHourPoint, at index: Int, from now: Date) -> String {
    if let date = hour.date { return date.formatted(.dateTime.hour()) }
    return now.addingTimeInterval(Double(index + 1) * secondsPerHour).formatted(.dateTime.hour())
}

/// The slice of the past+future timeline the UV graph draws: points stamped
/// in today's 9AM–7PM hours (device zone, like the formatted labels), plus
/// where now sits inside the slice. With fewer than two dated points
/// (dateless previews) it falls back to a 12-point window centered on the
/// now boundary, or everything when shorter. One computation shared by the
/// call-site gate and the curve's window var, so both read the same points —
/// callers pass the same now they label with.
func uvDayWindow(pastHours: [WeatherHourPoint], hours: [WeatherHourPoint], now: Date) -> (points: [WeatherHourPoint], nowPosition: Int) {
    // No future data means no window: past alone would clamp "Now" onto a
    // stale point.
    guard !hours.isEmpty else { return ([], 0) }
    let combined = pastHours + hours
    let boundary = min(pastHours.count, combined.count)
    if combined.filter({ $0.date != nil }).count >= 2 {
        let calendar = Calendar.current
        let dayPoints = combined.filter {
            guard let date = $0.date else { return false }
            guard calendar.isDate(date, inSameDayAs: now) else { return false }
            return WeatherUVStyle.dayHours.contains(calendar.component(.hour, from: date))
        }
        if dayPoints.count >= 2 {
            let position = dayPoints.firstIndex(where: { ($0.date ?? .distantPast) >= now })
                ?? (dayPoints.count - 1)
            return (dayPoints, position)
        }
    }
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
