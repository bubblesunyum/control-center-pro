// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPUI

@MainActor
final class PlaceholderSamplerTests: XCTestCase {
    func testItSamplesOnlyBetweenStartAndStop() {
        let sampler = PlaceholderSampler()
        XCTAssertFalse(sampler.isSampling)

        sampler.start()
        XCTAssertTrue(sampler.isSampling)

        sampler.stop()
        XCTAssertFalse(sampler.isSampling)
    }

    func testStartingTwiceKeepsOneTimer() {
        let sampler = PlaceholderSampler()

        sampler.start()
        sampler.start()
        sampler.stop()

        XCTAssertFalse(
            sampler.isSampling,
            "a second start that made a second task would leave one running here"
        )
    }

    func testStoppingOneThatNeverStartedIsFine() {
        let sampler = PlaceholderSampler()
        sampler.stop()
        XCTAssertFalse(sampler.isSampling)
    }
}
