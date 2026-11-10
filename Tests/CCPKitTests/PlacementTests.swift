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

    func testResizingSetsTheSizeAndNothingElse() {
        let layout = PanelLayout([[a, b]])

        XCTAssertEqual(
            layout.resizing(a, to: CustomWidgetSize(width: 347, height: 511)).lanes,
            [[Placement(id: a, customSize: CustomWidgetSize(width: 347, height: 511)), Placement(id: b)]]
        )
    }

    func testResizingAWidgetTheLayoutDoesNotPlaceChangesNothing() {
        let layout = PanelLayout([[a]])

        XCTAssertEqual(layout.resizing(b, to: CustomWidgetSize(width: 347, height: 511)), layout)
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

    func testMinimizedDefaultsToFalse() {
        XCTAssertFalse(Placement(id: a).isMinimized)
    }

    func testABareIDDecodesToAnExpandedPlacement() throws {
        let file = Data(#"{"lanes":[["a"]]}"#.utf8)
        let layout = try JSONDecoder().decode(PanelLayout.self, from: file)

        XCTAssertEqual(layout.lanes, [[Placement(id: a, isMinimized: false)]])
    }

    func testAMinimizedPlacementWithoutASpanDecodes() throws {
        let file = Data(#"{"lanes":[[{"id":"a","isMinimized":true}]]}"#.utf8)
        let layout = try JSONDecoder().decode(PanelLayout.self, from: file)

        XCTAssertEqual(layout.lanes, [[Placement(id: a, isMinimized: true)]])
    }

    /// A build from before minimizes existed reads what we write: expanded
    /// placements encode as the bare strings it already understands.
    func testExpandedPlacementsEncodeAsBareIDs() throws {
        struct OldLayout: Decodable {
            var lanes: [[WidgetID]]
        }
        let data = try JSONEncoder().encode(PanelLayout([[a, b]]))

        XCTAssertEqual(try JSONDecoder().decode(OldLayout.self, from: data).lanes, [[a, b]])
    }

    func testAMinimizedPlacementRoundTrips() throws {
        let layout = PanelLayout([[Placement(id: a, isMinimized: true), Placement(id: b)]])
        let decoded = try JSONDecoder().decode(
            PanelLayout.self,
            from: JSONEncoder().encode(layout)
        )

        XCTAssertEqual(decoded, layout)
    }

    func testAMinimizedAndSpannedPlacementRoundTrips() throws {
        let layout = PanelLayout([[Placement(id: a, span: WidgetSpan(width: 2, height: 2), isMinimized: true)]])
        let decoded = try JSONDecoder().decode(
            PanelLayout.self,
            from: JSONEncoder().encode(layout)
        )

        XCTAssertEqual(decoded, layout)
    }

    func testSettingMinimizedSetsTheFlagAndNothingElse() {
        let layout = PanelLayout([[Placement(id: a, span: WidgetSpan(width: 2, height: 1))]])

        XCTAssertEqual(
            layout.settingMinimized(a, to: true).lanes,
            [[Placement(id: a, span: WidgetSpan(width: 2, height: 1), isMinimized: true)]]
        )
        XCTAssertEqual(
            layout.settingMinimized(a, to: true).settingMinimized(a, to: false).lanes,
            [[Placement(id: a, span: WidgetSpan(width: 2, height: 1), isMinimized: false)]]
        )
    }

    func testSettingMinimizedOnAWidgetTheLayoutDoesNotPlaceChangesNothing() {
        let layout = PanelLayout([[a]])

        XCTAssertEqual(layout.settingMinimized(b, to: true), layout)
    }

    func testResizingPreservesMinimized() {
        let layout = PanelLayout([[Placement(id: a, isMinimized: true)]])

        XCTAssertEqual(
            layout.resizing(a, to: CustomWidgetSize(width: 347, height: 511)).lanes,
            [[Placement(id: a, isMinimized: true, customSize: CustomWidgetSize(width: 347, height: 511))]]
        )
    }

    func testSettingMinimizedKeepsTheSize() {
        let size = CustomWidgetSize(width: 347, height: 511)
        let layout = PanelLayout([[Placement(id: a, customSize: size)]])

        XCTAssertEqual(
            layout.settingMinimized(a, to: true).lanes,
            [[Placement(id: a, isMinimized: true, customSize: size)]],
            "a minimize once rebuilt the placement and dropped its size"
        )
    }

    func testMovingCarriesMinimizedAlong() {
        let layout = PanelLayout([[Placement(id: a, isMinimized: true), Placement(id: b)]])

        XCTAssertEqual(
            layout.moving(a, toLane: 0, at: 1).lanes,
            [[Placement(id: b), Placement(id: a, isMinimized: true)]]
        )
    }

    func testANewLaneCarriesMinimized() {
        let layout = PanelLayout([[Placement(id: a, isMinimized: true), Placement(id: b)]])

        XCTAssertEqual(
            layout.moving(a, toNewLaneAt: 0).lanes,
            [[Placement(id: a, isMinimized: true)], [Placement(id: b)]]
        )
    }

    func testNormalizedKeepsTheFirstPlacementMinimizedAndAll() {
        let layout = PanelLayout([[
            Placement(id: a, isMinimized: true),
            Placement(id: a),
        ]])

        XCTAssertEqual(
            layout.normalized().lanes,
            [[Placement(id: a, isMinimized: true)]]
        )
    }

    func testACustomSizeRoundTrips() throws {
        let layout = PanelLayout([[Placement(
            id: a, customSize: CustomWidgetSize(width: 347, height: 511)
        )]])
        let decoded = try JSONDecoder().decode(
            PanelLayout.self,
            from: JSONEncoder().encode(layout)
        )

        XCTAssertEqual(decoded, layout)
    }

    func testACustomPlacementWithoutASpanDecodes() throws {
        let file = Data(#"{"lanes":[[{"id":"a","customSize":{"width":347,"height":511}}]]}"#.utf8)
        let layout = try JSONDecoder().decode(PanelLayout.self, from: file)

        XCTAssertEqual(
            layout.lanes,
            [[Placement(id: a, customSize: CustomWidgetSize(width: 347, height: 511))]]
        )
    }

    func testOldFilesDecodeWithNilCustomSize() throws {
        let file = Data(#"{"lanes":[[{"id":"a","span":{"width":2,"height":2}}]]}"#.utf8)
        let layout = try JSONDecoder().decode(PanelLayout.self, from: file)

        XCTAssertNil(layout.lanes[0][0].customSize)
    }

    func testResizingKeepsALegacySpanOnDisk() {
        let layout = PanelLayout([[Placement(id: a, span: WidgetSpan(width: 2, height: 1))]])

        let resized = layout.resizing(a, to: CustomWidgetSize(width: 347, height: 511))

        XCTAssertEqual(resized.lanes[0][0].customSize, CustomWidgetSize(width: 347, height: 511))
        XCTAssertEqual(resized.lanes[0][0].span, WidgetSpan(width: 2, height: 1))
    }

    func testResolveAttachesEachPlacementCustomSize() {
        let slots = stubRegistry().resolve(PanelLayout([[
            Placement(id: StubWidget.descriptor.id, customSize: CustomWidgetSize(width: 347, height: 511)),
        ]]))

        XCTAssertEqual(slots[0][0].customSize, CustomWidgetSize(width: 347, height: 511))
    }
}
