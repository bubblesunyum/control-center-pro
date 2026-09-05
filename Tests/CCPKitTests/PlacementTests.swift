// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPKit

/// Placements: the size override travels with the widget, and a file written
/// before resizes existed still reads.
@MainActor
final class PlacementTests: XCTestCase {
    private let a: WidgetID = "a"
    private let b: WidgetID = "b"

    func testSpanClampsToUnitThroughMaximum() {
        XCTAssertEqual(WidgetSpan(width: 0, height: 99), WidgetSpan(width: 1, height: 3))
        XCTAssertEqual(WidgetSpan(width: -2, height: 2), WidgetSpan(width: 1, height: 2))
        XCTAssertEqual(WidgetSpan.unit, WidgetSpan(width: 1, height: 1))
    }

    func testABareIDDecodesToAUnitPlacement() throws {
        let file = Data(#"{"lanes":[["a"]]}"#.utf8)
        let layout = try JSONDecoder().decode(PanelLayout.self, from: file)

        XCTAssertEqual(layout.lanes, [[Placement(id: a)]])
    }

    func testAMixedLaneDecodes() throws {
        let file = Data(#"{"lanes":[[{"id":"a","span":{"width":2,"height":2}},"b",{"id":"c"}]]}"#.utf8)
        let layout = try JSONDecoder().decode(PanelLayout.self, from: file)

        XCTAssertEqual(
            layout.lanes,
            [[
                Placement(id: a, span: WidgetSpan(width: 2, height: 2)),
                Placement(id: b),
                Placement(id: "c"),
            ]]
        )
    }

    /// A build from before resizes existed reads what we write: unit
    /// placements encode as the bare strings it already understands.
    func testUnitPlacementsEncodeAsBareIDs() throws {
        struct OldLayout: Decodable {
            var lanes: [[WidgetID]]
        }
        let data = try JSONEncoder().encode(PanelLayout([[a, b]]))

        XCTAssertEqual(try JSONDecoder().decode(OldLayout.self, from: data).lanes, [[a, b]])
    }

    func testASpannedPlacementRoundTrips() throws {
        let layout = PanelLayout([[Placement(id: a, span: WidgetSpan(width: 2, height: 3)), Placement(id: b)]])
        let decoded = try JSONDecoder().decode(
            PanelLayout.self,
            from: JSONEncoder().encode(layout)
        )

        XCTAssertEqual(decoded, layout)
    }

    func testResizingSetsTheSpanAndNothingElse() {
        let layout = PanelLayout([[a, b]])

        XCTAssertEqual(
            layout.resizing(a, to: WidgetSpan(width: 2, height: 2)).lanes,
            [[Placement(id: a, span: WidgetSpan(width: 2, height: 2)), Placement(id: b)]]
        )
    }

    func testResizingAWidgetTheLayoutDoesNotPlaceChangesNothing() {
        let layout = PanelLayout([[a]])

        XCTAssertEqual(layout.resizing(b, to: WidgetSpan(width: 2, height: 2)), layout)
    }

    func testMovingCarriesTheSpanAlong() {
        let layout = PanelLayout([[Placement(id: a, span: WidgetSpan(width: 1, height: 2)), Placement(id: b)]])

        XCTAssertEqual(
            layout.moving(a, toLane: 0, at: 1).lanes,
            [[Placement(id: b), Placement(id: a, span: WidgetSpan(width: 1, height: 2))]]
        )
    }

    func testANewLaneCarriesTheSpan() {
        let layout = PanelLayout([[Placement(id: a, span: WidgetSpan(width: 2, height: 1)), Placement(id: b)]])

        XCTAssertEqual(
            layout.moving(a, toNewLaneAt: 0).lanes,
            [[Placement(id: a, span: WidgetSpan(width: 2, height: 1))], [Placement(id: b)]]
        )
    }

    func testNormalizedKeepsTheFirstPlacementSpanAndAll() {
        let layout = PanelLayout([[
            Placement(id: a, span: WidgetSpan(width: 2, height: 2)),
            Placement(id: a, span: WidgetSpan(width: 3, height: 3)),
        ]])

        XCTAssertEqual(
            layout.normalized().lanes,
            [[Placement(id: a, span: WidgetSpan(width: 2, height: 2))]]
        )
    }

    func testAddingPlacesAUnitWidget() {
        XCTAssertEqual(PanelLayout([[a]]).adding(b).lanes, [[Placement(id: a), Placement(id: b)]])
    }

    func testResolveAttachesEachPlacementSpan() {
        let slots = stubRegistry().resolve(PanelLayout([[
            Placement(id: StubWidget.descriptor.id, span: WidgetSpan(width: 2, height: 3)),
            Placement(id: OtherStubWidget.descriptor.id),
        ]]))

        XCTAssertEqual(slots[0][0].span, WidgetSpan(width: 2, height: 3))
        XCTAssertEqual(slots[0][1].span, .unit)
    }

    func testAnUnavailableSlotsSpanIsUnit() {
        let slots = stubRegistry().resolve(PanelLayout([[Placement(
            id: "widget-from-a-newer-build",
            span: WidgetSpan(width: 3, height: 3)
        )]]))

        XCTAssertEqual(slots[0][0].span, .unit, "there is no widget to resize")
    }

    func testOnlyScreensAreUnresizable() {
        for size in WidgetSize.allCases {
            XCTAssertEqual(size.isResizable, size != .screen, "\(size)")
        }
    }
}
