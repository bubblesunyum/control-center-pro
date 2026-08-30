// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPKit

@MainActor
final class PanelArrangementTests: XCTestCase {
    private let log = WidgetLifecycleLog.shared
    private let stub = StubWidget.descriptor.id
    private let other = OtherStubWidget.descriptor.id

    override func setUp() {
        super.setUp()
        log.reset()
    }

    private func arrangement(_ layout: PanelLayout) -> PanelArrangement {
        PanelArrangement(layout, registry: stubRegistry())
    }

    func testItNormalizesWhatItIsGiven() {
        let stored = PanelLayout([[stub], [], [stub]])

        XCTAssertEqual(
            arrangement(stored).layout,
            PanelLayout([[stub]]),
            "the empty lane closes up and the second placement is dropped"
        )
    }

    func testActivationReachesEveryPlacedWidget() {
        arrangement(PanelLayout([[stub], [other]])).activate()

        XCTAssertEqual(Set(log.activated), [stub, other])
    }

    /// The acceptance criterion for ccp-lr7.9: opening and closing all morning
    /// must not stack a timer per open inside every widget.
    func testTwentyOpensAndClosesStartAndStopOnceEach() {
        let panel = arrangement(PanelLayout([[stub]]))

        for _ in 0..<20 {
            panel.activate()
            panel.deactivate()
        }

        XCTAssertEqual(log.activated, Array(repeating: stub, count: 20))
        XCTAssertEqual(log.deactivated, Array(repeating: stub, count: 20))
    }

    func testActivatingTwiceStartsOnce() {
        let panel = arrangement(PanelLayout([[stub]]))

        panel.activate()
        panel.activate()

        XCTAssertEqual(log.activated, [stub])
    }

    func testDeactivatingAPanelThatWasNeverShownDoesNothing() {
        arrangement(PanelLayout([[stub]])).deactivate()

        XCTAssertEqual(log.deactivated, [])
    }

    func testASlotWithNoWidgetBehindItIsNotAskedToStart() {
        let panel = arrangement(PanelLayout([["widget-from-a-newer-build"]]))

        panel.activate()

        XCTAssertNil(panel.lanes[0][0].instance, "nothing to start, and nothing that crashed trying")
        XCTAssertEqual(log.activated, [])
    }
}
