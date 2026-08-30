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

/// Rearranging: what edit mode does to the arrangement, and what the widgets
/// living in it experience while it happens.
@MainActor
final class PanelArrangementRearrangingTests: XCTestCase {
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

    /// The point of keeping instances: a widget dragged across the panel is the
    /// same object when it lands, so whatever it was showing is still there.
    func testAMovedWidgetIsTheSameLiveWidget() {
        let panel = arrangement(PanelLayout([[stub], [other]]))
        let before = panel.slot(for: stub)?.instance

        panel.move(stub, toLane: 1, at: 0)

        XCTAssertIdentical(before, panel.slot(for: stub)?.instance)
        XCTAssertEqual(panel.layout.lanes, [[stub, other]])
    }

    func testAMovedWidgetIsNotRestarted() {
        let panel = arrangement(PanelLayout([[stub], [other]]))
        panel.activate()
        log.reset()

        panel.move(stub, toLane: 1, at: 1)

        XCTAssertEqual(log.activated, [], "it never stopped, so there is nothing to start")
        XCTAssertEqual(log.deactivated, [])
    }

    func testARemovedWidgetIsStopped() {
        let panel = arrangement(PanelLayout([[stub], [other]]))
        panel.activate()
        log.reset()

        panel.remove(stub)

        XCTAssertEqual(log.deactivated, [stub], "off the panel is as good as panel closed")
        XCTAssertNil(panel.slot(for: stub))
    }

    func testRemovingAWidgetFromAPanelThatWasNeverShownStopsNothing() {
        let panel = arrangement(PanelLayout([[stub], [other]]))

        panel.remove(stub)

        XCTAssertEqual(log.deactivated, [], "it was never sampling")
    }

    func testARemovedWidgetComesBackAsAFreshOne() {
        let panel = arrangement(PanelLayout([[stub], [other]]))
        let before = panel.slot(for: stub)?.instance

        panel.remove(stub)
        panel.move(other, toLane: 0, at: 0)

        XCTAssertNotIdentical(before, panel.slot(for: stub)?.instance)
    }

    func testAMoveThatChangesNothingIsNotAChange() {
        let panel = arrangement(PanelLayout([[stub, other]]))

        panel.move(stub, toLane: 0, at: 0)

        XCTAssertEqual(panel.layout.lanes, [[stub, other]])
    }

    func testRearrangingWritesTheLayoutOut() {
        let store = temporaryStore(default: PanelLayout.empty)
        let panel = PanelArrangement(
            PanelLayout([[stub], [other]]),
            registry: stubRegistry(),
            autosave: LayoutAutosave(store: store)
        )

        panel.move(stub, toLane: 1, at: 0)
        panel.flush()

        XCTAssertEqual(store.load().lanes, [[stub, other]])
    }
}
