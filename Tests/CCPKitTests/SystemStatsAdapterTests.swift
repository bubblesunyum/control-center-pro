// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import XCTest

@MainActor
final class SystemStatsAdapterTests: XCTestCase {
    // MARK: - Reporting

    func testReportsCPUUsageFromSource() {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(cpuUsage: 0.42))
        let adapter = SystemStatsAdapter(source: source)

        adapter.refresh()

        XCTAssertEqual(adapter.snapshot.cpuUsage, 0.42)
    }

    func testReportsMemoryFromSource() {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(
            memoryUsed: 4_000_000_000,
            memoryTotal: 16_000_000_000,
            memoryPressure: .warning
        ))
        let adapter = SystemStatsAdapter(source: source)

        adapter.refresh()

        XCTAssertEqual(adapter.snapshot.memoryUsed, 4_000_000_000)
        XCTAssertEqual(adapter.snapshot.memoryTotal, 16_000_000_000)
        XCTAssertEqual(adapter.snapshot.memoryPressure, .warning)
    }

    func testReportsTemperaturesFromSource() {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(
            cpuTemperature: 65,
            gpuTemperature: 72
        ))
        let adapter = SystemStatsAdapter(source: source)

        adapter.refresh()

        XCTAssertEqual(adapter.snapshot.cpuTemperature, 65)
        XCTAssertEqual(adapter.snapshot.gpuTemperature, 72)
    }

    func testReportsNetworkFromSource() {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(
            netDownBytesPerSec: 1_000_000,
            netUpBytesPerSec: 500_000
        ))
        let adapter = SystemStatsAdapter(source: source)

        adapter.refresh()

        XCTAssertEqual(adapter.snapshot.netDownBytesPerSec, 1_000_000)
        XCTAssertEqual(adapter.snapshot.netUpBytesPerSec, 500_000)
    }

    // MARK: - History

    func testCPUHistoryAccumulates() {
        let source = FakeSystemStatsSource()
        let adapter = SystemStatsAdapter(source: source, historyCapacity: 10)

        source.nextSample = SystemStatsSample(cpuUsage: 0.1)
        adapter.refresh()
        source.nextSample = SystemStatsSample(cpuUsage: 0.2)
        adapter.refresh()
        source.nextSample = SystemStatsSample(cpuUsage: 0.3)
        adapter.refresh()

        XCTAssertEqual(adapter.snapshot.cpuHistory, [0.1, 0.2, 0.3])
    }

    func testMemoryHistoryIsFraction() {
        let source = FakeSystemStatsSource()
        let adapter = SystemStatsAdapter(source: source, historyCapacity: 10)

        source.nextSample = SystemStatsSample(memoryUsed: 4_000, memoryTotal: 16_000, memoryPressure: .normal)
        adapter.refresh()
        source.nextSample = SystemStatsSample(memoryUsed: 8_000, memoryTotal: 16_000, memoryPressure: .normal)
        adapter.refresh()

        XCTAssertEqual(adapter.snapshot.memoryHistory, [0.25, 0.5])
    }

    func testNetworkHistoryAccumulates() {
        let source = FakeSystemStatsSource()
        let adapter = SystemStatsAdapter(source: source, historyCapacity: 10)

        source.nextSample = SystemStatsSample(netDownBytesPerSec: 100, netUpBytesPerSec: 50)
        adapter.refresh()
        source.nextSample = SystemStatsSample(netDownBytesPerSec: 200, netUpBytesPerSec: 60)
        adapter.refresh()

        XCTAssertEqual(adapter.snapshot.netDownHistory, [100, 200])
        XCTAssertEqual(adapter.snapshot.netUpHistory, [50, 60])
    }

    func testHistoryCapsAtCapacity() {
        let source = FakeSystemStatsSource()
        let adapter = SystemStatsAdapter(source: source, historyCapacity: 3)

        for i in 1...5 {
            source.nextSample = SystemStatsSample(cpuUsage: Double(i) / 10)
            adapter.refresh()
        }

        XCTAssertEqual(adapter.snapshot.cpuHistory, [0.3, 0.4, 0.5])
    }

    func testNilSampleDoesNotAdvanceHistory() {
        let source = FakeSystemStatsSource()
        let adapter = SystemStatsAdapter(source: source, historyCapacity: 10)

        source.nextSample = SystemStatsSample(cpuUsage: 0.5)
        adapter.refresh()
        let historyAfterFirst = adapter.snapshot.cpuHistory

        source.nextSample = SystemStatsSample(cpuUsage: nil)
        adapter.refresh()

        XCTAssertEqual(adapter.snapshot.cpuHistory, historyAfterFirst)
        XCTAssertEqual(adapter.snapshot.cpuUsage, 0.5, "nil sample should keep last known value")
    }

    // MARK: - Lifecycle

    func testActivateRefreshesImmediately() {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(cpuUsage: 0.9))
        let adapter = SystemStatsAdapter(source: source)

        XCTAssertNil(adapter.snapshot.cpuUsage)

        adapter.activate()

        XCTAssertEqual(adapter.snapshot.cpuUsage, 0.9)
        XCTAssertTrue(adapter.isSampling)

        adapter.deactivate()
    }

    func testActivateIsIdempotent() {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(cpuUsage: 0.5))
        let adapter = SystemStatsAdapter(source: source, interval: .milliseconds(20))

        adapter.activate()
        let countAfterFirst = source.sampleCount
        adapter.activate()
        XCTAssertEqual(source.sampleCount, countAfterFirst, "second activate should not trigger another immediate sample")

        adapter.deactivate()
    }

    func testDeactivateStopsSampling() async {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(cpuUsage: 0.1))
        let adapter = SystemStatsAdapter(source: source, interval: .milliseconds(20))

        adapter.activate()
        // Let a couple of interval ticks fire
        try? await Task.sleep(for: .milliseconds(60))
        let countWhileActive = source.sampleCount

        adapter.deactivate()
        XCTAssertFalse(adapter.isSampling)

        // Wait another interval; no new samples should arrive
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(source.sampleCount, countWhileActive, "a deactivated adapter kept sampling")
    }

    func testDeactivateCancelsImmediately() {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(cpuUsage: 0.1))
        let adapter = SystemStatsAdapter(source: source, interval: .milliseconds(10))

        adapter.activate()
        XCTAssertTrue(adapter.isSampling)

        adapter.deactivate()
        XCTAssertFalse(adapter.isSampling)
    }

    func testReactivatingSamplesAgain() {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(cpuUsage: 0.3))
        let adapter = SystemStatsAdapter(source: source)

        adapter.activate()
        adapter.deactivate()

        source.nextSample = SystemStatsSample(cpuUsage: 0.7)
        adapter.activate()

        XCTAssertEqual(adapter.snapshot.cpuUsage, 0.7)

        adapter.deactivate()
    }

    func testLiveGraphsWhileOpen() async {
        let source = FakeSystemStatsSource()
        source.sampleHandler = { _ in
            SystemStatsSample(cpuUsage: Double.random(in: 0...1))
        }
        let adapter = SystemStatsAdapter(source: source, interval: .milliseconds(20), historyCapacity: 10)

        adapter.activate()
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertGreaterThan(adapter.snapshot.cpuHistory.count, 2, "graph should have accumulated while open")

        adapter.deactivate()
        let historyAtClose = adapter.snapshot.cpuHistory
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(adapter.snapshot.cpuHistory, historyAtClose, "graph kept growing after close")
    }

    func testIdleCPUWithPanelShutIsZero() {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(cpuUsage: 0.5))
        let adapter = SystemStatsAdapter(source: source, interval: .milliseconds(10))

        XCTAssertFalse(adapter.isSampling)
        XCTAssertEqual(source.sampleCount, 0)

        adapter.activate()
        adapter.deactivate()

        XCTAssertFalse(adapter.isSampling)
    }
}

// MARK: - Fake

final class FakeSystemStatsSource: SystemStatsSource {
    var nextSample: SystemStatsSample
    var sampleHandler: ((TimeInterval) -> SystemStatsSample)?
    private(set) var sampleCount = 0

    init(sample: SystemStatsSample = SystemStatsSample()) {
        self.nextSample = sample
    }

    func sample(now: TimeInterval) -> SystemStatsSample {
        sampleCount += 1
        if let handler = sampleHandler {
            return handler(now)
        }
        return nextSample
    }
}
