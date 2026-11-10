// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
@testable import CCPUI
import XCTest

/// The window is a full-screen backdrop that swallows every click outside
/// the panel's own content, so a dismiss click never reaches the app below
/// (ccp-ecye — permanent behaviour). These pin the hit-test math that tells
/// content apart from backdrop: panel rects are top-leading origin, screen
/// points are bottom-leading, and the flip between them is where this would
/// go wrong.
final class BackdropHitTestTests: XCTestCase {
    /// A 1000×800 screen with lanes top-right and one sticky mid-screen.
    private let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let lanes = CGRect(x: 700, y: 20, width: 280, height: 400)

    private func sticky(_ trailingX: Double, _ y: Double) -> Sticky {
        // The window is 1000 wide: trailing 800 is the old leading 200.
        Sticky(trailingX: trailingX, y: y)
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
        return PanelBackdrop.isInteractive(
            at: point,
            windowFrame: window,
            hitRects: PanelBackdrop.hitRects(
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
    /// outside the panel and dismisses (swallowed, never reaching the app
    /// below). Without card frames the bounding box is the only answer and
    /// the gutter wrongly reads as the panel's — the fallback this pins, not
    /// the behaviour.
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

    func testANarrowGutterIsCoveredByEditSlack() {
        // Each card's slack reaches across a 10pt gutter, so a press aimed
        // at a grip or badge there stays on the panel.
        XCTAssertTrue(check(CGPoint(x: 835, y: 700), cards: twoCards, isEditing: true))
    }

    /// Lanes run the display's height, so their box covers glass the user
    /// sees as empty. Edit mode tests the cards, not the box: a click on
    /// empty glass leaves edit mode instead of doing nothing (ccp-kt7k).
    func testEmptyGlassIsBackdropWhileEditing() {
        // One short card in the corner of the lanes' box: panel (900, 300)
        // is inside the box, well clear of the card and its slack.
        let corner = [CGRect(x: 700, y: 20, width: 130, height: 200)]
        XCTAssertFalse(check(CGPoint(x: 900, y: 500), cards: corner, isEditing: true))
        XCTAssertTrue(check(CGPoint(x: 760, y: 700), cards: corner, isEditing: true))
    }

    func testEditModeSlackCoversOuterOverhang() {
        // The grip overshoot and badge cap past an edge card sit outside the
        // lanes' box; the slack keeps a press there on the panel.
        XCTAssertTrue(check(CGPoint(x: 985, y: 700), cards: twoCards, isEditing: true))
        XCTAssertFalse(check(CGPoint(x: 995, y: 700), cards: twoCards, isEditing: true))
    }

    func testEmptyPanelIsAllBackdrop() {
        // No cards and the box gone: nothing to click, so everything
        // dismisses — and is swallowed, never reaching the app below.
        XCTAssertFalse(check(CGPoint(x: 835, y: 700), cards: []))
        XCTAssertFalse(check(CGPoint(x: 800, y: 700), cards: []))
        // A sticky is still the panel's.
        XCTAssertTrue(check(
            CGPoint(x: 200, y: 200),
            cards: [],
            stickies: [sticky(800, 600)]
        ))
    }

    func testPointOnStickyIsInteractive() {
        // Center leading 200 (trailing 800), y 600 panel-space is (200, 200) on screen.
        XCTAssertTrue(check(CGPoint(x: 200, y: 200), stickies: [sticky(800, 600)]))
    }

    func testStickyCenterIsSufficientButNotRequired() {
        let note = sticky(800, 600)
        let halfW = StickyCard.defaultSize.width / 2
        let halfH = StickyCard.defaultSize.height / 2
        // Just inside the paper answers; just outside is backdrop. Screen
        // y runs bottom-leading against the panel's top-leading, hence the
        // mirrored vertical.
        XCTAssertTrue(check(CGPoint(x: 200 + halfW - 20, y: 200 - (halfH - 20)), stickies: [note]))
        XCTAssertFalse(check(CGPoint(x: 200 + halfW + 20, y: 200 - (halfH - 20)), stickies: [note]))
    }

    func testResizedStickyHitTestsItsStoredSize() {
        // A widened note answers across its full paper, not its old frame.
        var wide = sticky(800, 600)
        wide.width = 400
        XCTAssertTrue(check(CGPoint(x: 200 + 180, y: 200), stickies: [wide]))
        XCTAssertFalse(check(CGPoint(x: 200 + 220, y: 200), stickies: [wide]))
    }

    func testOpenGalleryMakesEverythingInteractive() {
        XCTAssertTrue(check(CGPoint(x: 100, y: 100), galleryOpen: true))
    }

    func testStickyUnderLanesStillCounts() {
        // Overlapping a sticky with the lanes changes nothing — depth is
        // fixed and both are the panel's.
        XCTAssertTrue(check(CGPoint(x: 800, y: 700), stickies: [sticky(200, 100)]))
    }

    // MARK: - Website bar overflow

    /// The website card the bar hangs off: 280×232 at the lanes' top.
    private var websiteCard: CGRect {
        CGRect(x: 700, y: 20, width: 280, height: 232)
    }

    /// The bar hung below the card, in panel space: leading-offset by the
    /// placement's x nudge, one bar-height tall. On screen this is x 708–908,
    /// y 504–548 bottom-leading — just under the card's 548–780 span.
    private var barBelowCard: CGRect {
        CGRect(
            x: websiteCard.minX + Space.one,
            y: websiteCard.maxY,
            width: WebsitePill.barWidth,
            height: WebsitePill.barHeight
        )
    }

    /// The bar flipped above a mid-panel card, in panel space. A top card's
    /// above-hang would sit half off screen, so this uses a lower card: panel
    /// y 156–200 reads as screen y 600–644 bottom-leading, over the card's
    /// 368–600 span.
    private var lowerWebsiteCard: CGRect {
        CGRect(x: 700, y: 200, width: 280, height: 232)
    }

    private var barAboveLowerCard: CGRect {
        CGRect(
            x: lowerWebsiteCard.minX + Space.one,
            y: lowerWebsiteCard.minY - WebsitePill.barHeight,
            width: WebsitePill.barWidth,
            height: WebsitePill.barHeight
        )
    }

    /// A hung bar counts as the panel's while its reported frame joins the
    /// union: every button across its width answers instead of dismissing.
    /// (Transparent pixels are unclickable at the view layer, but down here
    /// only the reported frame matters — the preference carries geometry,
    /// not pixels.)
    func testBarHungBelowCardCountsWhenItsFrameJoinsTheUnion() {
        let cards = [websiteCard, barBelowCard]
        XCTAssertTrue(check(CGPoint(x: 808, y: 526), cards: cards))
        // Leading button and trailing menu ends of the bar.
        XCTAssertTrue(check(CGPoint(x: 718, y: 526), cards: cards))
        XCTAssertTrue(check(CGPoint(x: 898, y: 526), cards: cards))
    }

    /// The reported failure: the bar hangs outside every card frame, so
    /// without its frame in the union a click on it reads as backdrop — the
    /// panel dismisses (and the click is swallowed, never reaching the app
    /// below) under the finger.
    func testBarHungBelowCardDismissesWhenItsFrameIsMissing() {
        XCTAssertFalse(check(CGPoint(x: 808, y: 526), cards: [websiteCard]))
        XCTAssertFalse(check(CGPoint(x: 718, y: 526), cards: [websiteCard]))
        XCTAssertFalse(check(CGPoint(x: 898, y: 526), cards: [websiteCard]))
    }

    func testBarHungAboveCardCountsWhenItsFrameJoinsTheUnion() {
        let cards = [lowerWebsiteCard, barAboveLowerCard]
        XCTAssertTrue(check(CGPoint(x: 808, y: 622), cards: cards))
        XCTAssertTrue(check(CGPoint(x: 718, y: 622), cards: cards))
        XCTAssertTrue(check(CGPoint(x: 898, y: 622), cards: cards))
    }

    func testBarHungAboveCardDismissesWhenItsFrameIsMissing() {
        XCTAssertFalse(check(CGPoint(x: 808, y: 622), cards: [lowerWebsiteCard]))
    }

    /// The overflow joins the union; it must not inflate it to a bounding
    /// box. The gutter between two cards still dismisses with a bar hung
    /// off one of them.
    func testGutterStillDismissesWithOverflowJoined() {
        let overflow = CGRect(
            x: twoCards[0].minX + Space.one,
            y: twoCards[0].maxY,
            width: WebsitePill.barWidth,
            height: WebsitePill.barHeight
        )
        XCTAssertFalse(check(CGPoint(x: 835, y: 700), cards: twoCards + [overflow]))
        // And the joined bar itself still answers.
        XCTAssertTrue(check(CGPoint(x: 808, y: 358), cards: twoCards + [overflow]))
    }
}
