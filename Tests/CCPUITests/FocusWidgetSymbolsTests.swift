// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import XCTest

/// Every symbol name the Focus card draws, outside the solid transport.
/// SF Symbols fail silent — a renamed symbol blanks its icon with no
/// error — so the names are pinned here rather than trusted.
final class FocusWidgetSymbolsTests: XCTestCase {
    func testFocusSymbolsResolve() {
        for name in ["timer", "mug", "arrow.counterclockwise", "forward"] {
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: name),
                "\(name) must resolve on this system"
            )
        }
    }
}
