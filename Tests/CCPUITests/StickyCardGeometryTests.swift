// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
@testable import CCPUI
import XCTest

/// The sticky card's own geometry: resize preview, editor inset, clamping,
/// and trailing-anchor resolution. These read the card's helpers directly,
/// never the backdrop hit-test.
final class StickyCardGeometryTests: XCTestCase {
    private func sticky(_ trailingX: Double, _ y: Double) -> Sticky {
        // The window is 1000 wide: trailing 800 is the old leading 200.
        Sticky(trailingX: trailingX, y: y)
    }

    func testResizePreviewRidesTheGrabbedCorner() {
        // The center rides half the translation so the grabbed corner tracks
        // the finger 1:1 and the opposite corner stands still.
        let note = sticky(800, 600)
        let preview = StickyCard.previewResize(from: note, translation: CGSize(width: 100, height: 60))
        XCTAssertEqual(preview.size, CGSize(width: note.width + 100, height: note.height + 60))
        XCTAssertEqual(preview.ride, CGSize(width: 50, height: 30))
        // At the minimum the ride freezes with the size: the corner stays
        // glued instead of detaching.
        let clamped = StickyCard.previewResize(from: note, translation: CGSize(width: -1000, height: -1000))
        XCTAssertEqual(clamped.size, CGSize(width: Sticky.minWidth, height: Sticky.minHeight))
        XCTAssertEqual(
            clamped.ride,
            CGSize(width: (Sticky.minWidth - note.width) / 2, height: (Sticky.minHeight - note.height) / 2)
        )
    }

    func testEditorSizeLeavesTheGrabPadding() {
        // The stored size is the whole card, paper border included, so the
        // text area is the card less that border on every side.
        XCTAssertEqual(
            StickyCard.editorSize(for: StickyCard.defaultSize),
            CGSize(
                width: StickyCard.defaultSize.width - StickyCard.edgeWidth * 2,
                height: StickyCard.defaultSize.height - StickyCard.edgeWidth * 2
            )
        )
        // Degenerate sizes pin at zero rather than inverting.
        XCTAssertEqual(StickyCard.editorSize(for: .zero), .zero)
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

    func testTrailingAnchorHoldsDistanceFromTheRightEdgeAcrossWidths() {
        // The desk's promise: the same trailing offset on a wider seat keeps
        // the same gap to the lanes. Trailing 800 is leading 200 at width
        // 1000; at 1400 the paper must sit 800 from the new right edge.
        let note = sticky(800, 600)
        let narrow = StickyCard.frame(of: note, inWidth: 1000)
        let wide = StickyCard.frame(of: note, inWidth: 1400)
        XCTAssertEqual(narrow.minX, 200 - StickyCard.defaultSize.width / 2)
        XCTAssertEqual(1000 - narrow.maxX, 1400 - wide.maxX)
        XCTAssertEqual(wide.minX - narrow.minX, 400)
        XCTAssertEqual(narrow.minY, wide.minY)
    }
}
