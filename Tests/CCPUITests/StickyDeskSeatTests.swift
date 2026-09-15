// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
@testable import CCPKit
@testable import CCPUI
import SwiftUI
import XCTest

/// A sticky drawn before the first show crashed launch (ccp-2esx): the seat
/// width was still `.greatestFiniteMagnitude`, so the desk drew cards at
/// x ≈ 1.8e308 and a clip layer went NaN. The default seat is a real display
/// width now; this seats a sticky in a hidden zero window the way launch
/// does, through the snapshot cycle that tripped it.
@MainActor
final class StickyDeskSeatTests: XCTestCase {
    func testFreshEditorSeatsOnAFiniteWidth() {
        let width = PanelEditor().displayWidth
        XCTAssertTrue(width.isFinite && width > 0)
    }

    func testCorruptCoordinatesDrawOnPlanet() {
        let sticky = Sticky(trailingX: 1e308, y: -1e308, width: 1e308, height: -5)
        let frame = StickyCard.frame(of: sticky, inWidth: 1440)
        XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite)
        XCTAssertLessThanOrEqual(abs(frame.midX), StickyCard.drawLimit)
        XCTAssertLessThanOrEqual(abs(frame.midY), StickyCard.drawLimit)
        XCTAssertLessThanOrEqual(frame.width, StickyCard.drawLimit)
        XCTAssertLessThanOrEqual(frame.height, StickyCard.drawLimit)
        XCTAssertGreaterThanOrEqual(frame.width, 0)
        XCTAssertGreaterThanOrEqual(frame.height, 0)
    }

    func testStickyInUnshownPanelSurvivesSnapshotCycle() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = StickyStore(directory: dir)
        // No network from a test: the seam reads as unconfigured, so seeding
        // never schedules a Craft push of the fixture.
        store.craftCredentialUnavailable = true
        let sticky = store.add(trailingX: 1495, y: 540)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: .zero),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView:
            StickyDesk(store: store, seatWidth: PanelEditor().displayWidth))
        window.layoutIfNeeded()
        try await Task.sleep(for: .seconds(10))

        // The cycle under test: appear draws the snapshot, which re-renders
        // the card. Proves the wait above covered it rather than idling past.
        XCTAssertNotNil(StickyEditorController.shared.snapshots[sticky.id])

        // Let an in-flight snapshot land before releasing, or its late write
        // re-seeds shared state after the keep below.
        window.contentView = nil
        let deadline = ContinuousClock.now + .seconds(3)
        while StickyEditorController.shared.snapshots[sticky.id] == nil,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        StickyEditorController.shared.keep(only: [])
    }
}
