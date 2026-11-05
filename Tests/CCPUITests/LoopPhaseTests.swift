// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPUI
import SwiftUI
import XCTest

/// The loop-phase machine behind the DesignSystem loops: starting takes two
/// legs (rest→low, then low→high under the forever), and stopping is always a
/// real change back to rest, so the forever animator is displaced instead of
/// ticking rest↔rest forever. These pin the transitions without rendering.
@MainActor
final class LoopPhaseTests: XCTestCase {
    func testStartMovesRestToLow() {
        XCTAssertEqual(LoopPhase.rest.start(), .low)
    }

    func testLoopMovesLowToHigh() {
        XCTAssertEqual(LoopPhase.low.loop(), .high)
    }

    func testStopFromHighSettlesToRest() {
        XCTAssertEqual(LoopPhase.high.stop(), .rest)
    }

    func testStopFromLowSettlesToRest() {
        XCTAssertEqual(LoopPhase.low.stop(), .rest)
    }

    func testStopBeforeStartChangesNothing() {
        XCTAssertNil(LoopPhase.rest.stop())
        XCTAssertTrue(LoopPhase.rest.isSettled)
    }

    func testHiddenPausesALoopingPhaseToRest() {
        // While active and visible the model sits at high; hiding settles it.
        // The view maps hidden to the stop leg, so this drives that leg.
        var phase = LoopPhase.high
        let shouldRun = false // isActive && isVisible
        if !shouldRun, let next = phase.stop() { phase = next }

        XCTAssertEqual(phase, .rest)
    }

    func testShownAgainResumesFromRest() {
        var phase = LoopPhase.rest
        let shouldRun = true // isActive && isVisible
        if shouldRun, let next = phase.start() { phase = next }
        XCTAssertEqual(phase, .low)
        if let next = phase.loop() { phase = next }
        XCTAssertEqual(phase, .high)
    }

    func testStartWhileAwayFromRestChangesNothing() {
        XCTAssertNil(LoopPhase.low.start())
        XCTAssertNil(LoopPhase.high.start())
    }

    func testLoopUnlessWaitingAtLow() {
        XCTAssertNil(LoopPhase.rest.loop())
        XCTAssertNil(LoopPhase.high.loop())
    }

    func testSettleLoopStopsAHighPhase() {
        var phase = LoopPhase.high
        LoopPhase.settleLoop(Binding(get: { phase }, set: { phase = $0 }), animation: .linear)

        XCTAssertEqual(phase, .rest)
    }

    func testSettleLoopLeavesRestUntouched() {
        var phase = LoopPhase.rest
        LoopPhase.settleLoop(Binding(get: { phase }, set: { phase = $0 }), animation: .linear)

        XCTAssertEqual(phase, .rest)
    }

    /// ccp-955m: this path wedged the full suite as a bare `await`
    /// of runLoop's 50ms entry-hop sleep — the sleep never resumed there
    /// while passing alone. It runs in a child task under a clock
    /// deadline, so a recurrence fails by timeout instead of wedging.
    func testRunLoopEndsAtHighFromRest() async throws {
        var phase = LoopPhase.rest
        let runner = Task { @MainActor in
            await LoopPhase.runLoop(
                Binding(get: { phase }, set: { phase = $0 }),
                entry: .linear, looping: .linear)
        }
        defer { runner.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while phase != .high {
            guard ContinuousClock.now < deadline else {
                return XCTFail("timed out waiting for runLoop to reach high")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await runner.value
        XCTAssertEqual(phase, .high)

        LoopPhase.settleLoop(
            Binding(get: { phase }, set: { phase = $0 }), animation: .linear)
        XCTAssertEqual(phase, .rest)
    }
}
