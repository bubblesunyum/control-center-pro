// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPKit

@MainActor
final class PanelLayoutTests: XCTestCase {
    private let unknown: WidgetID = "widget-from-a-newer-build"

    func testRoundTripsThroughJSON() throws {
        let layout = PanelLayout([
            [StubWidget.descriptor.id],
            [OtherStubWidget.descriptor.id, unknown],
        ])
        let decoded = try JSONDecoder().decode(
            PanelLayout.self,
            from: JSONEncoder().encode(layout)
        )
        XCTAssertEqual(decoded, layout)
    }

    func testUnknownIDDecodesIntact() throws {
        let file = Data(#"{"lanes":[["stub","widget-from-a-newer-build"]]}"#.utf8)
        let layout = try JSONDecoder().decode(PanelLayout.self, from: file)

        XCTAssertEqual(
            layout.lanes,
            [[StubWidget.descriptor.id, unknown]],
            "decoding reads the file, it does not judge it"
        )
    }

    func testUnknownIDResolvesToAnUnavailableSlot() {
        let slots = stubRegistry().resolve(PanelLayout([[StubWidget.descriptor.id, unknown]]))

        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots[0].map(\.id), [StubWidget.descriptor.id, unknown])
        guard case .widget = slots[0][0] else { return XCTFail("stub is in this build") }
        guard case .unavailable = slots[0][1] else { return XCTFail("the other one is not") }
    }

    func testUnknownIDSurvivesBeingSavedByABuildThatCannotRenderIt() throws {
        let store = temporaryStore(default: PanelLayout.empty)
        try store.save(PanelLayout([[StubWidget.descriptor.id, unknown]]))

        let reloaded = store.load().normalized()
        try store.save(reloaded)

        XCTAssertEqual(
            store.load().lanes,
            [[StubWidget.descriptor.id, unknown]],
            "a round trip through a build without the widget must not lose it"
        )
    }

    func testEmptyLanesAreClosedUp() {
        let layout = PanelLayout([[], [StubWidget.descriptor.id], []])
        XCTAssertEqual(layout.normalized().lanes, [[StubWidget.descriptor.id]])
    }

    func testRemovingTheLastWidgetLeavesOneEmptyLane() {
        XCTAssertEqual(PanelLayout([[], []]).normalized(), .empty)
        XCTAssertEqual(PanelLayout([]).normalized(), .empty)
        XCTAssertEqual(PanelLayout.empty.normalized(), .empty)
    }

    func testNormalizingKeepsOrderAndContents() {
        let layout = PanelLayout([
            [StubWidget.descriptor.id],
            [],
            [unknown, OtherStubWidget.descriptor.id],
        ])
        XCTAssertEqual(layout.normalized().lanes, [
            [StubWidget.descriptor.id],
            [unknown, OtherStubWidget.descriptor.id],
        ])
    }

    func testAWidgetIsPlacedOnlyOnce() {
        let layout = PanelLayout([
            [StubWidget.descriptor.id, OtherStubWidget.descriptor.id, StubWidget.descriptor.id],
            [OtherStubWidget.descriptor.id],
        ])
        XCTAssertEqual(layout.normalized().lanes, [
            [StubWidget.descriptor.id, OtherStubWidget.descriptor.id],
        ])
    }

    func testDroppingADuplicateCanEmptyALane() {
        let layout = PanelLayout([
            [StubWidget.descriptor.id],
            [StubWidget.descriptor.id],
        ])
        XCTAssertEqual(layout.normalized().lanes, [[StubWidget.descriptor.id]])
    }

    func testResolvedSlotIDsAreUniqueWithinALane() {
        let file = Data(#"{"lanes":[["stub","stub"]]}"#.utf8)
        let layout = try? JSONDecoder().decode(PanelLayout.self, from: file)
        let lanes = stubRegistry().resolve(layout?.normalized() ?? .empty)

        XCTAssertEqual(
            lanes.map { $0.map(\.id) },
            [[StubWidget.descriptor.id]],
            "a lane's slot ids are its ForEach identity and cannot repeat"
        )
    }
}
