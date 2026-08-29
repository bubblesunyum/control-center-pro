// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPKit

final class CCPKitTests: XCTestCase {
    /// Placeholder so `swift test` reports a real count rather than an empty
    /// suite the gate can't distinguish from a green one. Replaced by the
    /// registry tests in ccp-lr7.1.
    func testPackageIsWired() {
        XCTAssertTrue(CCPKit.isWired)
    }
}
