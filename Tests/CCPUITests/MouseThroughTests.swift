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
        cards: [CGRect]? = nil,
        isEditing: Bool = false,
        stickies: [Sticky] = [],
        galleryOpen: Bool = false,
        _ file: StaticString = #filePath,
        _ line: UInt = #line
    ) -> Bool {
        return ControlPanelController.isInteractive(
            at: point,
            windowFrame: window,
            hitRects: ControlPanelController.hitRects(
                lanesFrame: lanes,
                cardFrames: cards,
                isEditing: isEditing
            ),
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

    /// Two cards with a 10pt gutter between them, in panel space. The gutter
    /// is inside the lanes' bounding box but on no card: a click there is
    /// outside the panel and must fall through (ccp-ckyz). Without card
    /// frames the bounding box is the only answer and the gutter wrongly
    /// reads as the panel's — the fallback this pins, not the behaviour.
    private var twoCards: [CGRect] {
        [CGRect(x: 700, y: 20, width: 130, height: 400), CGRect(x: 840, y: 20, width: 140, height: 400)]
    }

    func testGutterBetweenCardsIsNotInteractive() {
        // Gutter runs x 830–840 panel-space, y 20–420 — on screen x 830–840,
        // y 380–780 bottom-leading.
        XCTAssertFalse(check(CGPoint(x: 835, y: 700), cards: twoCards))
        XCTAssertFalse(check(CGPoint(x: 835, y: 400), cards: twoCards))
    }

    func testPointOnCardStaysInteractive() {
        XCTAssertTrue(check(CGPoint(x: 800, y: 700), cards: twoCards))
        XCTAssertTrue(check(CGPoint(x: 900, y: 700), cards: twoCards))
    }

    func testGutterFallsBackToBoundingBoxBeforeCardFramesArrive() {
        XCTAssertTrue(check(CGPoint(x: 835, y: 700)))
    }

    func testGutterStaysInteractiveWhileEditing() {
        // The union would punch holes mid-gesture (the lifted card's gap,
        // the grip and badge overshoots), so edit mode keeps the box.
        XCTAssertTrue(check(CGPoint(x: 835, y: 700), cards: twoCards, isEditing: true))
    }

    func testEditModeSlackCoversOuterOverhang() {
        // The grip overshoot and badge cap past an edge card sit outside the
        // lanes' box; the slack keeps a press there on the panel.
        XCTAssertTrue(check(CGPoint(x: 985, y: 700), cards: twoCards, isEditing: true))
        XCTAssertFalse(check(CGPoint(x: 995, y: 700), cards: twoCards, isEditing: true))
    }

    func testEmptyPanelFallsThrough() {
        // No cards and the box gone: nothing to click, so nothing swallows.
        XCTAssertFalse(check(CGPoint(x: 835, y: 700), cards: []))
        XCTAssertFalse(check(CGPoint(x: 800, y: 700), cards: []))
        // A sticky is still the panel's.
        XCTAssertTrue(check(
            CGPoint(x: 200, y: 200),
            cards: [],
            stickies: [sticky(200, 600)]
        ))
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

    func testResizedStickyHitTestsItsStoredSize() {
        // A widened note answers across its full paper, not its old frame.
        var wide = sticky(200, 600)
        wide.width = 400
        XCTAssertTrue(check(CGPoint(x: 200 + 180, y: 200), stickies: [wide]))
        XCTAssertFalse(check(CGPoint(x: 200 + 220, y: 200), stickies: [wide]))
    }

    func testResizePreviewRidesTheGrabbedCorner() {
        // The center rides half the translation so the grabbed corner tracks
        // the finger 1:1 and the opposite corner stands still.
        let note = sticky(200, 600)
        let preview = StickyCard.previewResize(from: note, translation: CGSize(width: 100, height: 60))
        XCTAssertEqual(preview.size, CGSize(width: 340, height: 252))
        XCTAssertEqual(preview.ride, CGSize(width: 50, height: 30))
        // At the minimum the ride freezes with the size: the corner stays
        // glued instead of detaching.
        let clamped = StickyCard.previewResize(from: note, translation: CGSize(width: -1000, height: -1000))
        XCTAssertEqual(clamped.size, CGSize(width: Sticky.minWidth, height: Sticky.minHeight))
        XCTAssertEqual(
            clamped.ride,
            CGSize(width: (Sticky.minWidth - 240) / 2, height: (Sticky.minHeight - 192) / 2)
        )
    }

    func testOpenGalleryMakesEverythingInteractive() {
        XCTAssertTrue(check(CGPoint(x: 100, y: 100), galleryOpen: true))
    }

    func testStickyUnderLanesStillCounts() {
        // Overlapping a sticky with the lanes changes nothing — depth is
        // fixed and both are the panel's.
        XCTAssertTrue(check(CGPoint(x: 800, y: 700), stickies: [sticky(800, 100)]))
    }

    func testClampedCenterKeepsTheGrabStripReachable() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        // Flung off every edge comes back to just the grab rim.
        let far = StickyCard.clampedCenter(
            CGPoint(x: 5000, y: -5000),
            size: StickyCard.defaultSize,
            in: bounds
        )
        XCTAssertEqual(
            far,
            CGPoint(
                x: 1000 - StickyCard.minGrab + StickyCard.defaultSize.width / 2,
                y: StickyCard.defaultSize.height / 2 - StickyCard.edgeWidth
            )
        )
        // A resized note clamps by its own size, not the default's.
        let bigFar = StickyCard.clampedCenter(
            CGPoint(x: 5000, y: -5000),
            size: CGSize(width: 400, height: 300),
            in: bounds
        )
        XCTAssertEqual(
            bigFar,
            CGPoint(
                x: 1000 - StickyCard.minGrab + 200,
                y: 150 - StickyCard.edgeWidth
            )
        )
        // Partially off-screen is fine and stays put.
        XCTAssertEqual(
            StickyCard.clampedCenter(CGPoint(x: 990, y: 790), size: StickyCard.defaultSize, in: bounds),
            CGPoint(x: 990, y: 790)
        )
        XCTAssertEqual(
            StickyCard.clampedCenter(CGPoint(x: 500, y: 400), size: StickyCard.defaultSize, in: bounds),
            CGPoint(x: 500, y: 400)
        )
    }
}
