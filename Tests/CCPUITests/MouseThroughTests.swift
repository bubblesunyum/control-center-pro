// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
@testable import CCPUI
import XCTest

/// The window covers the screen and ignores the pointer everywhere the panel
/// isn't, so clicks reach the app below. These pin the hit-test math: panel
/// rects are top-leading origin, screen points are bottom-leading, and the
/// flip between them is where this would go wrong.
final class MouseThroughTests: XCTestCase {
    /// A 1000×800 screen with lanes top-right and one sticky mid-screen.
    private let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let lanes = CGRect(x: 700, y: 20, width: 280, height: 400)

    private func sticky(_ x: Double, _ y: Double) -> Sticky {
        Sticky(x: x, y: y)
    }

    private func check(
        _ point: CGPoint,
        stickies: [Sticky] = [],
        galleryOpen: Bool = false,
        _ file: StaticString = #filePath,
        _ line: UInt = #line
    ) -> Bool {
        ControlPanelController.isInteractive(
            at: point,
            windowFrame: window,
            lanesFrame: lanes,
            stickies: stickies,
            galleryOpen: galleryOpen
        )
    }

    func testPointInLanesIsInteractive() {
        // Lanes run x 700–980 panel-space, y 20–420 — the same box on screen
        // is x 700–980, y 380–780 bottom-leading.
        XCTAssertTrue(check(CGPoint(x: 800, y: 700)))
    }

    func testPointInEmptyScreenIsNot() {
        XCTAssertFalse(check(CGPoint(x: 100, y: 100)))
        XCTAssertFalse(check(CGPoint(x: 800, y: 100)))
    }

    func testPointOnStickyIsInteractive() {
        // Center (200, 600) panel-space is (200, 200) on screen.
        XCTAssertTrue(check(CGPoint(x: 200, y: 200), stickies: [sticky(200, 600)]))
    }

    func testStickyCenterIsSufficientButNotRequired() {
        let note = sticky(200, 600)
        // 240×192 card: the corner inside is interactive, just outside isn't.
        XCTAssertTrue(check(CGPoint(x: 200 + 100, y: 200 + 80), stickies: [note]))
        XCTAssertFalse(check(CGPoint(x: 200 + 140, y: 200 + 120), stickies: [note]))
    }

    func testOpenGalleryMakesEverythingInteractive() {
        XCTAssertTrue(check(CGPoint(x: 100, y: 100), galleryOpen: true))
    }

    func testStickyUnderLanesStillCounts() {
        // Overlapping a sticky with the lanes changes nothing — depth is
        // fixed and both are the panel's.
        XCTAssertTrue(check(CGPoint(x: 800, y: 700), stickies: [sticky(800, 100)]))
    }

    func testClampedCenterKeepsTheHeaderReachable() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        // Flung off every edge comes back to just the grab strip.
        let far = StickyCard.clampedCenter(CGPoint(x: 5000, y: -5000), in: bounds)
        XCTAssertEqual(
            far,
            CGPoint(
                x: 1000 - StickyCard.minGrab + StickyCard.size.width / 2,
                y: StickyCard.size.height / 2 - StickyCard.headerHeight
            )
        )
        // Partially off-screen is fine and stays put.
        XCTAssertEqual(
            StickyCard.clampedCenter(CGPoint(x: 990, y: 790), in: bounds),
            CGPoint(x: 990, y: 790)
        )
        XCTAssertEqual(
            StickyCard.clampedCenter(CGPoint(x: 500, y: 400), in: bounds),
            CGPoint(x: 500, y: 400)
        )
    }
}
