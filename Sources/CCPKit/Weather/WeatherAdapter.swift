// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import Observation

/// How far a weather fetch got.
public enum WeatherLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case failed
}

/// The weather widget's model: fetches while the panel is open, idles at 0%
/// when shut.
///
/// Follows the widget lifecycle: `activate(lat:lon:)` when the panel opens
/// and `deactivate()` when it closes. The caller passes coordinates — this
/// type never touches CoreLocation, and persists nothing; location storage
/// is the settings bead's job. Engine work (network + decode) runs in the
/// source off the main thread; the published snapshot is always set on main.
@MainActor
@Observable
public final class WeatherAdapter {
    public private(set) var snapshot: WeatherSnapshot?
    public private(set) var state: WeatherLoadState = .idle
    public private(set) var lastUpdated: Date?
    public private(set) var lastError: WeatherError?

    @ObservationIgnored private let source: WeatherSource
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var latitude: Double?
    @ObservationIgnored private var longitude: Double?
    @ObservationIgnored private let refreshInterval: Duration

    public static let defaultRefreshInterval = Duration.seconds(15 * 60)

    /// Live adapter against Open-Meteo. The session is injectable so previews
    /// can stub the endpoint.
    public convenience init(session: URLSession = .shared) {
        self.init(source: LiveOpenMeteoSource(session: session))
    }

    public init(
        source: WeatherSource,
        refreshInterval: Duration = defaultRefreshInterval,
        initialSnapshot: WeatherSnapshot? = nil
    ) {
        self.source = source
        self.refreshInterval = refreshInterval
        self.snapshot = initialSnapshot
        if initialSnapshot != nil { state = .loaded }
    }

    /// Start fetching for these coordinates, refreshing on the interval.
    /// Idempotent — a second open while already open updates the location
    /// without stacking a second timer.
    public func activate(lat: Double, lon: Double) {
        latitude = lat
        longitude = lon
        guard task == nil else { return }
        let interval = refreshInterval
        task = Task { [weak self] in
            guard let self else { return }
            await self.loadCurrent()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.loadCurrent()
            }
        }
    }

    /// Stop fetching. Cancels synchronously so a shut panel costs nothing.
    public func deactivate() {
        task?.cancel()
        task = nil
    }

    public var isRefreshing: Bool { task != nil }

    /// One fetch for these coordinates, published on main. The fetch and
    /// decode run in the source off the main thread; this hop only assigns.
    /// Useful for tests and for pull-to-refresh if the widget ever grows one.
    public func load(lat: Double, lon: Double) async {
        latitude = lat
        longitude = lon
        await loadCurrent()
    }

    private func loadCurrent() async {
        guard let lat = latitude, let lon = longitude else { return }
        // First load shows a spinner; background refreshes keep the stale
        // snapshot on screen so the card does not flash every 15 minutes.
        if snapshot == nil { state = .loading }
        do {
            let fresh = try await source.fetch(lat: lat, lon: lon)
            guard !Task.isCancelled else { return }
            snapshot = fresh
            state = .loaded
            lastUpdated = Date()
            lastError = nil
        } catch is CancellationError {
            return
        } catch let error as WeatherError {
            guard !Task.isCancelled else { return }
            if snapshot == nil { state = .failed }
            lastError = error
        } catch {
            guard !Task.isCancelled else { return }
            if snapshot == nil { state = .failed }
            lastError = .unavailable
        }
    }
}
