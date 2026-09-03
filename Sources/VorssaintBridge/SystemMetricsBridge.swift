// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Darwin
import Foundation
import IOKit

// MARK: - Public restatements of upstream metric types

/// Memory pressure as reported by the kernel, same three levels upstream uses.
public enum BridgedMemoryPressure: String, Sendable, Equatable, CaseIterable {
    case normal
    case warning
    case critical
    case unknown
}

/// One memory reading, as `SystemInfo.memoryUsage()` computes it.
public struct BridgedMemorySample: Sendable, Equatable {
    public var used: UInt64
    public var appUsed: UInt64
    public var total: UInt64
    public var compressed: UInt64
    public var cached: UInt64
    public var swapUsed: UInt64?
    public var pressure: BridgedMemoryPressure

    public init(
        used: UInt64,
        appUsed: UInt64,
        total: UInt64,
        compressed: UInt64,
        cached: UInt64,
        swapUsed: UInt64?,
        pressure: BridgedMemoryPressure
    ) {
        self.used = used
        self.appUsed = appUsed
        self.total = total
        self.compressed = compressed
        self.cached = cached
        self.swapUsed = swapUsed
        self.pressure = pressure
    }
}

/// One network reading, as `NetworkSampler.sample(now:)` computes it.
public struct BridgedNetworkSample: Sendable, Equatable {
    public var downBytesPerSec: Double?
    public var upBytesPerSec: Double?
    public var totalDown: UInt64
    public var totalUp: UInt64
}

/// One temperature set, as the SMC + `TemperatureSensorSelector` compute it.
public struct BridgedTemperatureSample: Sendable, Equatable {
    public var cpu: Double?
    public var gpu: Double?
    public var battery: Double?
}

/// One power reading, covering the built-in battery when present.
public struct BridgedPowerSample: Sendable, Equatable {
    public var chargePercent: Int?
    public var isCharging: Bool
    public var externalConnected: Bool
    public var hasBattery: Bool

    public init(chargePercent: Int? = nil, isCharging: Bool = false, externalConnected: Bool = false, hasBattery: Bool = false) {
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.hasBattery = hasBattery
    }
}

// MARK: - Sampling engine (wraps upstream samplers)

/// Wraps the Metrics and SystemMonitor samplers so `CCPKit` can read them
/// without naming an upstream type.
///
/// This is a visibility shim: each method restates what the engine already
/// does, with no policy about when to sample, how often, or what to do with
/// the result. The adapter in `CCPKit` owns intervals, history and the
/// `activate`/`deactivate` lifecycle.
/// Actor-isolated so a `Task.detached` off the main thread and a
/// synchronous `activate`/`refresh` on the main thread never touch
/// `NetworkSampler.previous` or `SMCClient.connection` at the same time.
/// Upstream's own `SystemMonitor` serializes on its own queue; this is the
/// same invariant for the shim.
public actor BridgedMetricsSampler {
    private var previousCPUTicks: (busy: UInt64, total: UInt64)?
    private let networkSampler = NetworkSampler()
    private var smc: SMCClient?
    private var smcTried = false
    private var cpuKeys: [SMCClient.Key] = []
    private var preferredCPUKeys: [SMCClient.Key] = []
    private var fallbackCPUKeys: [SMCClient.Key] = []
    private var gpuKeys: [SMCClient.Key] = []
    private var batteryKeys: [SMCClient.Key] = []
    private var tempKeysPrepared = false
    private var cpuTemperaturePlatform: CPUTemperaturePlatform = .generic
    private var cpuTemperatureCache: CachedSensorReading?
    private var gpuTemperatureCache: CachedSensorReading?
    private var batteryTemperatureCache: CachedSensorReading?
    private var powerSampler: PowerSampler?
    private var lastGPUUsage: Double?

    public init() {}

    // MARK: CPU

    /// CPU usage as a 0...1 fraction, derived from `HOST_CPU_LOAD_INFO`.
    /// Returns `nil` on the first call (no previous tick to diff against) or
    /// when the kernel call fails, mirroring `SystemMonitor.readCPUUsage()`.
    public func cpuUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let busy = user &+ system &+ nice
        let total = busy &+ idle
        defer { previousCPUTicks = (busy, total) }
        guard let previous = previousCPUTicks, total > previous.total else { return nil }
        let busyDelta = busy >= previous.busy ? busy - previous.busy : 0
        let totalDelta = total - previous.total
        guard totalDelta > 0 else { return nil }
        return Double(busyDelta) / Double(totalDelta)
    }

    // MARK: Memory

    public func memorySample() -> BridgedMemorySample? {
        guard let memory = SystemInfo.memoryUsage() else { return nil }
        let pressure = Self.readMemoryPressure().bridged
        return BridgedMemorySample(
            used: memory.used,
            appUsed: memory.appUsed,
            total: memory.total,
            compressed: memory.compressed,
            cached: memory.cached,
            swapUsed: memory.swapUsed,
            pressure: pressure
        )
    }

    private static func readMemoryPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .unknown
        }
        return MemoryPressure(kernelLevel: level)
    }

    // MARK: Network

    public func networkSample(now: TimeInterval) -> BridgedNetworkSample {
        let reading = networkSampler.sample(now: now)
        return BridgedNetworkSample(
            downBytesPerSec: reading.downBytesPerSec,
            upBytesPerSec: reading.upBytesPerSec,
            totalDown: reading.totalDown,
            totalUp: reading.totalUp
        )
    }

    // MARK: Temperatures

    public func temperatureSample(now: TimeInterval) -> BridgedTemperatureSample {
        prepareIfNeeded()
        let gap: TimeInterval = 12
        let cpu = TemperatureSensorSelector.stabilizedTemperature(
            cpuTemperature(),
            cache: &cpuTemperatureCache,
            now: now,
            maxAge: gap,
            minimum: TemperatureSensorSelector.minimumChipTemperature)
        let gpu = TemperatureSensorSelector.stabilizedTemperature(
            maxTemperature(of: gpuKeys),
            cache: &gpuTemperatureCache,
            now: now,
            maxAge: gap)
        let battery = TemperatureSensorSelector.stabilizedTemperature(
            maxTemperature(of: batteryKeys),
            cache: &batteryTemperatureCache,
            now: now,
            maxAge: gap)
        return BridgedTemperatureSample(cpu: cpu, gpu: gpu, battery: battery)
    }

    private func cpuTemperature() -> Double? {
        guard smc != nil else { return nil }
        var readings = temperatureReadings(of: preferredCPUKeys)
        if let value = TemperatureSensorSelector.displayedCPUTemperature(
            readings: readings, platform: cpuTemperaturePlatform) {
            return value
        }
        readings += temperatureReadings(of: fallbackCPUKeys)
        return TemperatureSensorSelector.displayedCPUTemperature(
            readings: readings, platform: cpuTemperaturePlatform)
    }

    private func maxTemperature(of keys: [SMCClient.Key]) -> Double? {
        guard let smc else { return nil }
        let values = keys.compactMap { key -> Double? in
            guard let v = smc.readValue(key), v > 1, v < 125 else { return nil }
            return v
        }
        return values.max()
    }

    private func temperatureReadings(of keys: [SMCClient.Key]) -> [(key: String, value: Double)] {
        guard let smc else { return [] }
        return keys.compactMap { key -> (key: String, value: Double)? in
            guard let value = smc.readValue(key) else { return nil }
            return (key.name, value)
        }
    }

    // MARK: GPU

    /// GPU usage 0...1, mirroring `SystemMonitor.readGPUUsage()` plus the same
    /// stabilization that hides compositor spikes when the panel repaints.
    public func gpuUsage() -> Double? {
        guard let raw = Self.readGPUUsage() else { return nil }
        let stabilized = MetricFormat.stabilizedGPUUsage(previous: lastGPUUsage, current: raw)
        lastGPUUsage = stabilized
        return stabilized
    }

    private static func readGPUUsage() -> Double? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let current = entry
            // Advance before any return so the pending next entry is not leaked.
            entry = IOIteratorNext(iterator)
            guard let ref = IORegistryEntryCreateCFProperty(current, "PerformanceStatistics" as CFString,
                                                            kCFAllocatorDefault, 0),
                  let stats = ref.takeRetainedValue() as? [String: Any],
                  let utilization = stats["Device Utilization %"] as? Int
            else {
                IOObjectRelease(current)
                continue
            }
            IOObjectRelease(current)
            return Double(utilization) / 100.0
        }
        return nil
    }

    // MARK: Power / Battery

    public func powerSample() -> BridgedPowerSample {
        ensurePowerSampler()
        guard let sampler = powerSampler else {
            return BridgedPowerSample(hasBattery: PowerSampler.hasInternalBattery)
        }
        let reading = sampler.sample()
        return BridgedPowerSample(
            chargePercent: reading.chargePercent,
            isCharging: reading.isCharging,
            externalConnected: reading.externalConnected,
            hasBattery: reading.hasBattery
        )
    }

    private func ensurePowerSampler() {
        if powerSampler != nil { return }
        if !smcTried {
            smcTried = true
            smc = SMCClient()
            cpuTemperaturePlatform = TemperatureSensorSelector.currentPlatform()
        }
        if let smc {
            powerSampler = PowerSampler(smc: smc)
        } else if PowerSampler.hasInternalBattery {
            powerSampler = PowerSampler(smc: nil)
        }
    }

    private func prepareIfNeeded() {
        if !smcTried {
            smcTried = true
            smc = SMCClient()
            cpuTemperaturePlatform = TemperatureSensorSelector.currentPlatform()
        }
        guard let client = smc, !tempKeysPrepared else {
            ensurePowerSampler()
            return
        }
        tempKeysPrepared = true
        let all = client.keys { name in
            TemperatureSensorSelector.isCPUTemperatureKey(name, platform: cpuTemperaturePlatform)
                || name.hasPrefix("Tg")
                || name.range(of: "^TB[0-9]T$", options: .regularExpression) != nil
        }
        cpuKeys = all.filter {
            TemperatureSensorSelector.isCPUTemperatureKey($0.name, platform: cpuTemperaturePlatform)
        }
        preferredCPUKeys = cpuKeys.filter {
            TemperatureSensorSelector.isCPUCoreKey($0.name, platform: cpuTemperaturePlatform)
        }
        let preferredNames = Set(preferredCPUKeys.map(\.name))
        fallbackCPUKeys = TemperatureSensorSelector.hasCPUCoreSet(platform: cpuTemperaturePlatform)
            ? [] : cpuKeys.filter { !preferredNames.contains($0.name) }
        gpuKeys = all.filter { $0.name.hasPrefix("Tg") }
        batteryKeys = all.filter { $0.name.hasPrefix("TB") }
        ensurePowerSampler()
    }
}

private extension MemoryPressure {
    var bridged: BridgedMemoryPressure {
        switch self {
        case .normal: return .normal
        case .warning: return .warning
        case .critical: return .critical
        case .unknown: return .unknown
        }
    }
}
