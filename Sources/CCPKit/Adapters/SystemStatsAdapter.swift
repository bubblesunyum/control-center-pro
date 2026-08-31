// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import Observation
import VorssaintEngines

// MARK: - Public snapshot

/// What the System Stats card shows at one instant.
///
/// Plain values and histories; the widget decides how to draw them and the
/// persisted layout never sees them.
public struct SystemStatsSnapshot: Sendable, Equatable {
    public var cpuUsage: Double? // 0...1
    public var cpuHistory: [Double]
    public var memoryUsed: UInt64?
    public var memoryTotal: UInt64?
    public var memoryPressure: SystemMemoryPressure
    public var memoryHistory: [Double] // 0...1 fraction
    public var cpuTemperature: Double?
    public var gpuTemperature: Double?
    public var netDownBytesPerSec: Double?
    public var netUpBytesPerSec: Double?
    public var netDownHistory: [Double]
    public var netUpHistory: [Double]

    public init(
        cpuUsage: Double? = nil,
        cpuHistory: [Double] = [],
        memoryUsed: UInt64? = nil,
        memoryTotal: UInt64? = nil,
        memoryPressure: SystemMemoryPressure = .unknown,
        memoryHistory: [Double] = [],
        cpuTemperature: Double? = nil,
        gpuTemperature: Double? = nil,
        netDownBytesPerSec: Double? = nil,
        netUpBytesPerSec: Double? = nil,
        netDownHistory: [Double] = [],
        netUpHistory: [Double] = []
    ) {
        self.cpuUsage = cpuUsage
        self.cpuHistory = cpuHistory
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.memoryPressure = memoryPressure
        self.memoryHistory = memoryHistory
        self.cpuTemperature = cpuTemperature
        self.gpuTemperature = gpuTemperature
        self.netDownBytesPerSec = netDownBytesPerSec
        self.netUpBytesPerSec = netUpBytesPerSec
        self.netDownHistory = netDownHistory
        self.netUpHistory = netUpHistory
    }

    public static let empty = SystemStatsSnapshot()
}

public enum SystemMemoryPressure: String, Sendable, Equatable, CaseIterable {
    case normal
    case warning
    case critical
    case unknown
}

// MARK: - Sampling source

/// Where system numbers come from.
///
/// The seam a test stands a fake in for: real kernel and SMC reads are not
/// something a test can arrange, so nothing above this protocol talks to the
/// system directly.
public protocol SystemStatsSource: AnyObject, Sendable {
    func sample(now: TimeInterval) async -> SystemStatsSample
}

/// One instantaneous reading from the system. Histories are the adapter's job;
/// this is just what's true now.
public struct SystemStatsSample: Sendable, Equatable {
    public var cpuUsage: Double?
    public var memoryUsed: UInt64?
    public var memoryTotal: UInt64?
    public var memoryPressure: SystemMemoryPressure?
    public var cpuTemperature: Double?
    public var gpuTemperature: Double?
    public var netDownBytesPerSec: Double?
    public var netUpBytesPerSec: Double?
    public var netTotalDown: UInt64?
    public var netTotalUp: UInt64?

    public init(
        cpuUsage: Double? = nil,
        memoryUsed: UInt64? = nil,
        memoryTotal: UInt64? = nil,
        memoryPressure: SystemMemoryPressure? = nil,
        cpuTemperature: Double? = nil,
        gpuTemperature: Double? = nil,
        netDownBytesPerSec: Double? = nil,
        netUpBytesPerSec: Double? = nil,
        netTotalDown: UInt64? = nil,
        netTotalUp: UInt64? = nil
    ) {
        self.cpuUsage = cpuUsage
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.memoryPressure = memoryPressure
        self.cpuTemperature = cpuTemperature
        self.gpuTemperature = gpuTemperature
        self.netDownBytesPerSec = netDownBytesPerSec
        self.netUpBytesPerSec = netUpBytesPerSec
        self.netTotalDown = netTotalDown
        self.netTotalUp = netTotalUp
    }
}

/// The real one, reading through the engine bridge.
/// Isolated to the sampler actor so `NetworkSampler.previous` and `SMCClient`
/// are never touched concurrently from `activate` and the interval loop.
public final class LiveSystemStatsSource: SystemStatsSource {
    private let sampler = BridgedMetricsSampler()

    public init() {}

    public func sample(now: TimeInterval) async -> SystemStatsSample {
        let cpu = await sampler.cpuUsage()
        let memory = await sampler.memorySample()
        let temps = await sampler.temperatureSample(now: now)
        let network = await sampler.networkSample(now: now)
        return SystemStatsSample(
            cpuUsage: cpu,
            memoryUsed: memory?.used,
            memoryTotal: memory?.total,
            memoryPressure: memory.map { SystemMemoryPressure(bridged: $0.pressure) },
            cpuTemperature: temps.cpu,
            gpuTemperature: temps.gpu,
            netDownBytesPerSec: network.downBytesPerSec,
            netUpBytesPerSec: network.upBytesPerSec,
            netTotalDown: network.totalDown,
            netTotalUp: network.totalUp
        )
    }
}

// MARK: - Adapter

/// The widget's model: samples while the panel is open and idles at 0% when shut.
///
/// Follows the widget lifecycle: `activate()` when the panel opens and
/// `deactivate()` when it closes. Engine work runs off the main thread; the
/// published snapshot is always set on main.
@MainActor
@Observable
public final class SystemStatsAdapter {
    public private(set) var snapshot: SystemStatsSnapshot

    @ObservationIgnored private let source: SystemStatsSource
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let historyCapacity: Int

    /// Idle history storage is kept in the snapshot itself, but the live ring
    /// is capped so a panel left open for hours does not grow without bound.
    public static let defaultHistoryCapacity = 60
    public static let defaultInterval = Duration.seconds(1)

    public convenience init() {
        self.init(source: LiveSystemStatsSource())
    }

    public init(
        source: SystemStatsSource,
        interval: Duration = defaultInterval,
        historyCapacity: Int = defaultHistoryCapacity,
        initialSnapshot: SystemStatsSnapshot = .empty
    ) {
        self.source = source
        self.interval = interval
        self.historyCapacity = max(1, historyCapacity)
        self.snapshot = initialSnapshot
    }

    /// Start sampling. Idempotent — a second open while already open does not
    /// stack a second timer.
    ///
    /// The first sample is taken off the main thread: `BridgedMetricsSampler`
    /// touches `SMCClient` and `host_statistics`, and the first call enumerates
    /// hundreds of SMC keys. Doing that on `MainActor` would stall the panel's
    /// 100ms open animation (see `SystemMetricsBridge.swift:211`).
    public func activate() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            // Immediate sample off main so the card has something to draw within
            // one tick without paying main-thread cost.
            await self.refresh()
            let interval = await self.interval
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    /// Stop sampling. Cancels synchronously so a shut panel costs nothing even
    /// if the next tick was due in milliseconds.
    public func deactivate() {
        task?.cancel()
        task = nil
    }

    public var isSampling: Bool { task != nil }

    /// One sample, published on main. Engine work runs on the sampler actor;
    /// this hop keeps the main thread free. Useful for tests and for the
    /// immediate sample in `activate()`.
    public func refresh() async {
        let now = ProcessInfo.processInfo.systemUptime
        let sample = await source.sample(now: now)
        guard !Task.isCancelled else { return }
        apply(sample)
    }

    private func apply(_ sample: SystemStatsSample) {
        var next = snapshot

        if let cpu = sample.cpuUsage {
            next.cpuUsage = cpu
            next.cpuHistory = appending(next.cpuHistory, value: cpu)
        }

        if let used = sample.memoryUsed, let total = sample.memoryTotal {
            next.memoryUsed = used
            next.memoryTotal = total
            if let pressure = sample.memoryPressure {
                next.memoryPressure = pressure
            }
            if total > 0 {
                let fraction = Double(used) / Double(total)
                next.memoryHistory = appending(next.memoryHistory, value: fraction)
            }
        } else if let pressure = sample.memoryPressure {
            next.memoryPressure = pressure
        }

        if let cpuTemp = sample.cpuTemperature {
            next.cpuTemperature = cpuTemp
        }
        if let gpuTemp = sample.gpuTemperature {
            next.gpuTemperature = gpuTemp
        }

        if let down = sample.netDownBytesPerSec {
            next.netDownBytesPerSec = down
            next.netDownHistory = appending(next.netDownHistory, value: down)
        }
        if let up = sample.netUpBytesPerSec {
            next.netUpBytesPerSec = up
            next.netUpHistory = appending(next.netUpHistory, value: up)
        }

        snapshot = next
    }

    private func appending(_ history: [Double], value: Double) -> [Double] {
        var next = history
        next.append(value)
        if next.count > historyCapacity {
            next.removeFirst(next.count - historyCapacity)
        }
        return next
    }
}

private extension SystemMemoryPressure {
    init(bridged: BridgedMemoryPressure) {
        switch bridged {
        case .normal: self = .normal
        case .warning: self = .warning
        case .critical: self = .critical
        case .unknown: self = .unknown
        }
    }
}
