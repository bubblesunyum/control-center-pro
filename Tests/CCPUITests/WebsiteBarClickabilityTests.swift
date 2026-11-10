// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI
import XCTest
@testable import CCPUI

/// The website bar's clickability contract, proved without laying anything
/// out: the reported overflow frame joins the backdrop union, and a single
/// gate decides whether the bar hit-tests at all.
///
/// The view half of this lives in WebsiteWidget.pillBar/pillContent and is
/// deliberately not reached here — sources are outside this partition — so
/// the gate test below is a spec mirror of `pillVisible`, shaped for rewiring
/// once the helper is extracted (see the EXTRACTION note). Everything else
/// pins current pure API: the preference union, the placement offsets, and
/// the report formula.
final class WebsiteBarClickabilityTests: XCTestCase {
    // MARK: - Overflow union

    func testHiddenOverflowStartsEmpty() {
        // The preference's default: a hidden bar hit-tests nothing. This is
        // the empty side of the `pillVisible ? [frame] : []` report — no
        // frame, no hit-test, no third state at the union layer.
        XCTAssertEqual(PanelOverflowFramePreference.defaultValue, [])
    }

    func testVisibleOverflowJoinsTheUnion() {
        // Each visible bar's frame accumulates: two bars hang two frames,
        // and the backdrop counts both as the panel's.
        let first = CGRect(x: 708, y: 252, width: 200, height: 44)
        let second = CGRect(x: 708, y: 156, width: 200, height: 44)
        var union: [CGRect] = []
        PanelOverflowFramePreference.reduce(value: &union, nextValue: { [first] })
        PanelOverflowFramePreference.reduce(value: &union, nextValue: { [second] })
        XCTAssertEqual(union, [first, second])
    }

    func testHiddenBarReportsNothingToTheUnion() {
        // A hidden bar reports [] and the union is untouched: the cards
        // alone decide, and the bar's pixels sit on backdrop (dismiss, and
        // the click is swallowed — dismiss-clicks-are-swallowed).
        var union = [CGRect(x: 700, y: 20, width: 280, height: 232)]
        PanelOverflowFramePreference.reduce(value: &union, nextValue: { [] })
        XCTAssertEqual(union, [CGRect(x: 700, y: 20, width: 280, height: 232)])
    }

    // MARK: - Hang geometry

    func testHangOffsetsStepExactlyOneBarHeight() {
        // The bar hangs off the card's edge, never over the page: below goes
        // down one barHeight, above goes up one barHeight — the "offset by
        // barHeight" the backdrop union relies on to cover the drawn bar.
        XCTAssertEqual(WebsitePill.Placement.belowLeading.yOffset, WebsitePill.barHeight)
        XCTAssertEqual(WebsitePill.Placement.belowTrailing.yOffset, WebsitePill.barHeight)
        XCTAssertEqual(WebsitePill.Placement.aboveLeading.yOffset, -WebsitePill.barHeight)
        XCTAssertEqual(WebsitePill.Placement.aboveTrailing.yOffset, -WebsitePill.barHeight)
    }

    func testHangOffsetsNudgeOffTheSummonedSide() {
        // Leading hangs nudge right, trailing hangs nudge left, by one
        // spacing unit — clear of the card's edge either way.
        XCTAssertEqual(WebsitePill.Placement.belowLeading.xOffset, Space.one)
        XCTAssertEqual(WebsitePill.Placement.aboveLeading.xOffset, Space.one)
        XCTAssertEqual(WebsitePill.Placement.belowTrailing.xOffset, -Space.one)
        XCTAssertEqual(WebsitePill.Placement.aboveTrailing.xOffset, -Space.one)
    }

    func testReportedFrameIsLayoutFrameShiftedByPlacement() {
        // Mirrors WebsiteWidget.pillBar's report: `offset` shifts drawing
        // post-layout, so the measured pre-offset box needs the same shift
        // to match the drawn bar — a background sits at the pre-offset box.
        let layout = CGRect(x: 700, y: 228, width: 200, height: 44)
        let below = WebsitePill.Placement.belowLeading
        XCTAssertEqual(
            layout.offsetBy(dx: below.xOffset, dy: below.yOffset),
            CGRect(x: 708, y: 272, width: 200, height: 44)
        )
        let above = WebsitePill.Placement.aboveTrailing
        XCTAssertEqual(
            layout.offsetBy(dx: above.xOffset, dy: above.yOffset),
            CGRect(x: 692, y: 184, width: 200, height: 44)
        )
    }

    // MARK: - Single interaction gate (spec mirror)

    /// SPEC MIRROR of WebsiteContent.pillVisible
    /// (`isHoveringPill || focusedControl != nil`): the only switch for bar
    /// hit-testing — opacity and allowsHitTesting move together, no extra
    /// .disabled on containers.
    ///
    /// EXTRACTION FOLLOW-UP: this tests the spec copy, not the source — the
    /// state is private to the view. Move the helper into WebsitePill (e.g.
    /// `WebsitePill.barVisible(isHoveringPill:hasKeyboardFocus:)`), drive
    /// `pillVisible` from it, and rewire these tests to call it. Until then
    /// they pin the contract the extraction must satisfy: hidden => no
    /// hit-test, visible => hit-test, no third state.
    ///
    /// Why one gate matters: allowsHitTesting(false) kills the whole subtree
    /// (allows-hittesting-false-kills-the-subtree) — a container-level
    /// .disabled/.allowsHitTesting/.opacity layer would shadow every button
    /// including the Menu label, whose own contentShape keeps it clickable
    /// only while the single gate is open.
    private func specBarVisible(isHoveringPill: Bool, hasKeyboardFocus: Bool) -> Bool {
        isHoveringPill || hasKeyboardFocus
    }

    func testSingleGateHiddenMeansNoHitTest() {
        XCTAssertFalse(specBarVisible(isHoveringPill: false, hasKeyboardFocus: false))
    }

    func testSingleGateHoverOrFocusMeansHitTest() {
        XCTAssertTrue(specBarVisible(isHoveringPill: true, hasKeyboardFocus: false))
        XCTAssertTrue(specBarVisible(isHoveringPill: false, hasKeyboardFocus: true))
        XCTAssertTrue(specBarVisible(isHoveringPill: true, hasKeyboardFocus: true))
    }
}
