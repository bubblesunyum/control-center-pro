// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPUI
import Observation
import XCTest

/// The panel hides without tearing its views down, so `onPanelHidden` has
/// nothing to listen to but this. These pin what it listens for: a going-away
/// is published, and an open is not a going-away.
@MainActor
final class PanelVisibilityTests: XCTestCase {
    func testStartsDown() {
        XCTAssertFalse(PanelVisibility().isVisible)
    }

    func testHidePublishesTheChange() {
        let visibility = PanelVisibility()
        visibility.show()

        var told = false
        withObservationTracking { _ = visibility.isVisible } onChange: { told = true }
        visibility.hide()

        XCTAssertTrue(told)
        XCTAssertFalse(visibility.isVisible)
    }

    func testShowPublishesTheChange() {
        let visibility = PanelVisibility()

        var told = false
        withObservationTracking { _ = visibility.isVisible } onChange: { told = true }
        visibility.show()

        XCTAssertTrue(told)
        XCTAssertTrue(visibility.isVisible)
    }

    /// Re-hiding an already-down panel is not a second going-away: the
    /// cleanup it drives pops a cursor, and an unpaired pop is a bug.
    func testHidingTwiceReportsOnce() {
        let visibility = PanelVisibility()
        visibility.show()
        visibility.hide()

        var tellings = 0
        withObservationTracking { _ = visibility.isVisible } onChange: { tellings += 1 }
        visibility.hide()

        XCTAssertEqual(tellings, 0)
    }
}
