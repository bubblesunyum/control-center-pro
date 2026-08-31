// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import XCTest

@MainActor
final class SystemStatsAdapterTests: XCTestCase {
    // MARK: - Reporting

    func testReportsCPUUsageFromSource() async {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(cpuUsage: 0.42))
        let adapter = SystemStatsAdapter(source: source)

        await adapter.refresh()

        XCTAssertEqual(adapter.snapshot.cpuUsage, 0.42)
    }

    func testReportsMemoryFromSource() async {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(
            memoryUsed: 4_000_000_000,
            memoryTotal: 16_000_000_000,
            memoryPressure: .warning
        ))
        let adapter = SystemStatsAdapter(source: source)

        await adapter.refresh()

        XCTAssertEqual(adapter.snapshot.memoryUsed, 4_000_000_000)
        XCTAssertEqual(adapter.snapshot.memoryTotal, 16_000_000_000)
        XCTAssertEqual(adapter.snapshot.memoryPressure, .warning)
    }

    func testReportsTemperaturesFromSource() async {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(
            cpuTemperature: 65,
            gpuTemperature: 72
        ))
        let adapter = SystemStatsAdapter(source: source)

        await adapter.refresh()

        XCTAssertEqual(adapter.snapshot.cpuTemperature, 65)
        XCTAssertEqual(adapter.snapshot.gpuTemperature, 72)
    }

    func testReportsNetworkFromSource() async {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(
            netDownBytesPerSec: 1_000_000,
            netUpBytesPerSec: 500_000
        ))
        let adapter = SystemStatsAdapter(source: source)

        await adapter.refresh()

        XCTAssertEqual(adapter.snapshot.netDownBytesPerSec, 1_000_000)
        XCTAssertEqual(adapter.snapshot.netUpBytesPerSec, 500_000)
    }

    // MARK: - History

    func testCPUHistoryAccumulates() async {
        let source = FakeSystemStatsSource()
        let adapter = SystemStatsAdapter(source: source, historyCapacity: 10)

        source.nextSample = SystemStatsSample(cpuUsage: 0.1)
        await adapter.refresh()
        source.nextSample = SystemStatsSample(cpuUsage: 0.2)
        await adapter.refresh()
        source.nextSample = SystemStatsSample(cpuUsage: 0.3)
        await adapter.refresh()

        XCTAssertEqual(adapter.snapshot.cpuHistory, [0.1, 0.2, 0.3])
    }

    func testMemoryHistoryIsFraction() async {
        let source = FakeSystemStatsSource()
        let adapter = SystemStatsAdapter(source: source, historyCapacity: 10)

        source.nextSample = SystemStatsSample(memoryUsed: 4_000, memoryTotal: 16_000, memoryPressure: .normal)
        await adapter.refresh()
        source.nextSample = SystemStatsSample(memoryUsed: 8_000, memoryTotal: 16_000, memoryPressure: .normal)
        await adapter.refresh()

        XCTAssertEqual(adapter.snapshot.memoryHistory, [0.25, 0.5])
    }

    func testNetworkHistoryAccumulates() async {
        let source = FakeSystemStatsSource()
        let adapter = SystemStatsAdapter(source: source, historyCapacity: 10)

        source.nextSample = SystemStatsSample(netDownBytesPerSec: 100, netUpBytesPerSec: 50)
        await adapter.refresh()
        source.nextSample = SystemStatsSample(netDownBytesPerSec: 200, netUpBytesPerSec: 60)
        await adapter.refresh()

        XCTAssertEqual(adapter.snapshot.netDownHistory, [100, 200])
        XCTAssertEqual(adapter.snapshot.netUpHistory, [50, 60])
    }

    func testHistoryCapsAtCapacity() async {
        let source = FakeSystemStatsSource()
        let adapter = SystemStatsAdapter(source: source, historyCapacity: 3)

        for i in 1...5 {
            source.nextSample = SystemStatsSample(cpuUsage: Double(i) / 10)
            await adapter.refresh()
        }

        XCTAssertEqual(adapter.snapshot.cpuHistory, [0.3, 0.4, 0.5])
    }

    func testNilSampleDoesNotAdvanceHistory() async {
        let source = FakeSystemStatsSource()
        let adapter = SystemStatsAdapter(source: source, historyCapacity: 10)

        source.nextSample = SystemStatsSample(cpuUsage: 0.5)
        await adapter.refresh()
        let historyAfterFirst = adapter.snapshot.cpuHistory

        source.nextSample = SystemStatsSample(cpuUsage: nil)
        await adapter.refresh()

        XCTAssertEqual(adapter.snapshot.cpuHistory, historyAfterFirst)
        XCTAssertEqual(adapter.snapshot.cpuUsage, 0.5, "nil sample should keep last known value")
    }

    // MARK: - Lifecycle

    func testActivateSamplesOffMain() async {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(cpuUsage: 0.9))
        let adapter = SystemStatsAdapter(source: source, interval: .milliseconds(50))

        XCTAssertNil(adapter.snapshot.cpuUsage)

        adapter.activate()
        // First sample is now off the main thread; give it a turn.
        let saw = await becomesTrue { adapter.snapshot.cpuUsage == 0.9 }
        XCTAssertTrue(saw, "activate should sample without blocking main")
        XCTAssertTrue(adapter.isSampling)

        adapter.deactivate()
    }

    func testActivateIsIdempotent() async {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(cpuUsage: 0.5))
        let adapter = SystemStatsAdapter(source: source, interval: .milliseconds(20))

        adapter.activate()
        // Wait for first async sample
        _ = await becomesTrue { source.sampleCount >= 1 }
        let countAfterFirst = source.sampleCount
        adapter.activate()
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(source.sampleCount, countAfterFirst, "second activate should not trigger another immediate sample")

        adapter.deactivate()
    }

    func testDeactivateStopsSampling() async {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(cpuUsage: 0.1))
        let adapter = SystemStatsAdapter(source: source, interval: .milliseconds(20))

        adapter.activate()
        _ = await becomesTrue { source.sampleCount >= 2 }
        let countWhileActive = source.sampleCount

        adapter.deactivate()
        XCTAssertFalse(adapter.isSampling)

        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(source.sampleCount, countWhileActive, "a deactivated adapter kept sampling")
    }

    func testDeactivateCancelsImmediately() async {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(cpuUsage: 0.1))
        let adapter = SystemStatsAdapter(source: source, interval: .milliseconds(10))

        adapter.activate()
        XCTAssertTrue(adapter.isSampling)

        adapter.deactivate()
        XCTAssertFalse(adapter.isSampling)
    }

    func testReactivatingSamplesAgain() async {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(cpuUsage: 0.3))
        let adapter = SystemStatsAdapter(source: source, interval: .milliseconds(50))

        adapter.activate()
        _ = await becomesTrue { adapter.snapshot.cpuUsage == 0.3 }
        adapter.deactivate()

        source.nextSample = SystemStatsSample(cpuUsage: 0.7)
        adapter.activate()
        let saw = await becomesTrue { adapter.snapshot.cpuUsage == 0.7 }
        XCTAssertTrue(saw)

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

    func testIdleCPUWithPanelShutIsZero() async {
        let source = FakeSystemStatsSource(sample: SystemStatsSample(cpuUsage: 0.5))
        let adapter = SystemStatsAdapter(source: source, interval: .milliseconds(10))

        XCTAssertFalse(adapter.isSampling)
        XCTAssertEqual(source.sampleCount, 0)

        adapter.activate()
        _ = await becomesTrue { source.sampleCount >= 1 }
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

    func sample(now: TimeInterval) async -> SystemStatsSample {
        sampleCount += 1
        if let handler = sampleHandler {
            return handler(now)
        }
        return nextSample
    }
}
