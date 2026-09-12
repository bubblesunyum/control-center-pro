// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPUI

/// The decision table behind Copy Text's Screen Recording gate: the system
/// prompt is one-shot and a grant needs a relaunch, so it fires once and
/// later denied taps point at Settings instead.
@MainActor
final class CopyTextCaptureGateTests: XCTestCase {
    func testGrantedProceedsWhetherOrNotWePromptedBefore() {
        XCTAssertEqual(CopyTextCaptureGate.action(granted: true, alreadyPrompted: false), .proceed)
        XCTAssertEqual(CopyTextCaptureGate.action(granted: true, alreadyPrompted: true), .proceed)
    }

    func testFirstDeniedTapPromptsTheSystem() {
        XCTAssertEqual(CopyTextCaptureGate.action(granted: false, alreadyPrompted: false), .promptSystem)
    }

    func testLaterDeniedTapsPointAtSettings() {
        XCTAssertEqual(CopyTextCaptureGate.action(granted: false, alreadyPrompted: true), .settingsHint)
    }

    func testSettingsOpensWhenNeverOpened() {
        XCTAssertTrue(CopyTextCaptureGate.shouldOpenSettings(lastOpened: nil, now: Date()))
    }

    func testSettingsThrottlesRapidReTaps() {
        let now = Date()
        XCTAssertFalse(CopyTextCaptureGate.shouldOpenSettings(
            lastOpened: now.addingTimeInterval(-1), now: now))
        XCTAssertTrue(CopyTextCaptureGate.shouldOpenSettings(
            lastOpened: now.addingTimeInterval(-6), now: now))
    }
}
