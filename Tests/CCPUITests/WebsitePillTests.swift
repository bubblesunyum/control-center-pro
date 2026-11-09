// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI
import XCTest
@testable import CCPUI

/// The website bar's hang without laying anything out: which corner a hover
/// summons it from, and where it hangs for that corner and the room around
/// the card.
final class WebsitePillTests: XCTestCase {
    private let size = CGSize(width: 300, height: 232)

    func testEachCornerSummonsFromItsZone() {
        XCTAssertEqual(WebsitePill.corner(at: CGPoint(x: 10, y: 10), in: size), .topLeading)
        XCTAssertEqual(WebsitePill.corner(at: CGPoint(x: 290, y: 10), in: size), .topTrailing)
        XCTAssertEqual(WebsitePill.corner(at: CGPoint(x: 10, y: 222), in: size), .bottomLeading)
        XCTAssertEqual(WebsitePill.corner(at: CGPoint(x: 290, y: 222), in: size), .bottomTrailing)
    }

    func testTheMiddleSummonsNothing() {
        XCTAssertNil(WebsitePill.corner(at: CGPoint(x: 150, y: 116), in: size))
        // Near an edge but not a corner: still nothing.
        XCTAssertNil(WebsitePill.corner(at: CGPoint(x: 10, y: 116), in: size))
        XCTAssertNil(WebsitePill.corner(at: CGPoint(x: 150, y: 10), in: size))
    }

    func testAHoveredCornerHangsOffItsOwnSide() {
        XCTAssertEqual(
            WebsitePill.placement(for: .bottomLeading, drawnWidth: 300, barWidth: 200, roomAbove: true, roomBelow: true),
            .belowLeading
        )
        XCTAssertEqual(
            WebsitePill.placement(for: .bottomTrailing, drawnWidth: 300, barWidth: 200, roomAbove: true, roomBelow: true),
            .belowTrailing
        )
        XCTAssertEqual(
            WebsitePill.placement(for: .topLeading, drawnWidth: 300, barWidth: 200, roomAbove: true, roomBelow: true),
            .aboveLeading
        )
        XCTAssertEqual(
            WebsitePill.placement(for: .topTrailing, drawnWidth: 300, barWidth: 200, roomAbove: true, roomBelow: true),
            .aboveTrailing
        )
    }

    func testAHangWithoutRoomFlipsTowardRoom() {
        // A bottom corner near the display's bottom hangs above.
        XCTAssertEqual(
            WebsitePill.placement(for: .bottomLeading, drawnWidth: 300, barWidth: 200, roomAbove: true, roomBelow: false),
            .aboveLeading
        )
        // A top corner under the menu bar hangs below.
        XCTAssertEqual(
            WebsitePill.placement(for: .topLeading, drawnWidth: 300, barWidth: 200, roomAbove: false, roomBelow: true),
            .belowLeading
        )
        // A keyboard summon hangs below until the display says otherwise.
        XCTAssertEqual(
            WebsitePill.placement(for: nil, drawnWidth: 300, barWidth: 200, roomAbove: true, roomBelow: true),
            .belowLeading
        )
        XCTAssertEqual(
            WebsitePill.placement(for: nil, drawnWidth: 300, barWidth: 200, roomAbove: true, roomBelow: false),
            .aboveLeading
        )
    }

    func testACardNarrowerThanTheBarHangsOffTheTrailingSide() {
        // Hanging left always has desktop; hanging right past a right-seated
        // panel is off screen — so a narrow card flips to trailing whatever
        // corner summoned the bar.
        XCTAssertEqual(
            WebsitePill.placement(for: .bottomLeading, drawnWidth: 100, barWidth: 200, roomAbove: true, roomBelow: true),
            .belowTrailing
        )
        XCTAssertEqual(
            WebsitePill.placement(for: .topLeading, drawnWidth: 100, barWidth: 200, roomAbove: true, roomBelow: true),
            .aboveTrailing
        )
    }
}
