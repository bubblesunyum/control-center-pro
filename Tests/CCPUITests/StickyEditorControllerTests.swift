// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
@testable import CCPUI
import XCTest

/// A sticky nobody is typing in is drawn by the shared editor page, off
/// screen, at its own size.
@MainActor
final class StickyEditorControllerTests: XCTestCase {
    func testAnUnfocusedStickyGetsASnapshotAtItsSize() async throws {
        let editing = StickyEditorController.shared
        let sticky = Sticky(text: "# Groceries  \n- [ ] milk", trailingX: 0, y: 0)
        let size = CGSize(width: 180, height: 120)
        defer { editing.keep(only: []) }

        editing.redraw(sticky, size: size)

        let deadline = ContinuousClock.now + .seconds(10)
        while editing.snapshots[sticky.id] == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let image = try XCTUnwrap(editing.snapshots[sticky.id], "no snapshot drawn")
        XCTAssertEqual(image.size, size)
        XCTAssertNil(editing.focusedStickyID)
    }
}
