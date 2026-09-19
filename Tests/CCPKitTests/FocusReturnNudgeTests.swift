// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
@testable import CCPKit
import XCTest

final class FakeFocusActivity: FocusActivitySource, @unchecked Sendable {
    var idle: TimeInterval = .greatestFiniteMagnitude
    func idleSeconds() -> TimeInterval { idle }
}

@MainActor
final class FocusReturnNudgeTests: XCTestCase {
    private func freshDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(
        in directory: URL? = nil,
        clock: ManualFocusClock? = nil,
        notifier: FakeFocusNotifier? = nil,
        activity: FakeFocusActivity? = nil
    ) -> (FocusStore, ManualFocusClock, FakeFocusNotifier, FakeFocusActivity) {
        let clock = clock ?? ManualFocusClock()
        clock.nowDate = Calendar.current.date(
            bySettingHour: 12, minute: 0, second: 0, of: clock.nowDate
        ) ?? clock.nowDate
        let notifier = notifier ?? FakeFocusNotifier()
        let activity = activity ?? FakeFocusActivity()
        let store = FocusStore(
            in: directory ?? freshDirectory(), clock: clock,
            notifier: notifier, activity: activity)
        return (store, clock, notifier, activity)
    }

    private func completeFocus(
        _ store: FocusStore, _ clock: ManualFocusClock, focusMinutes: Int = 25
    ) {
        store.updateSettings(FocusSettings(
            focusMinutes: focusMinutes, shortBreakMinutes: 5))
        store.start(.focus)
        clock.advance(by: TimeInterval(focusMinutes * 60 + 1))
        store.tick()
        XCTAssertNil(store.activePhase)
    }

    func testFiresAfterDelayOnActivity() {
        let (store, clock, notifier, activity) = makeStore()
        completeFocus(store, clock)

        // Before the delay, activity changes nothing.
        clock.advance(by: 11 * 60)
        activity.idle = 5
        store.checkReturnNudge()
        XCTAssertEqual(notifier.returnNudgeCount, 0)

        // Past 12 minutes with fresh activity, it fires.
        clock.advance(by: 2 * 60)
        activity.idle = 5
        store.checkReturnNudge()
        XCTAssertEqual(notifier.returnNudgeCount, 1)
    }

    func testStaysQuietWhileAway() {
        let (store, clock, notifier, activity) = makeStore()
        completeFocus(store, clock)

        clock.advance(by: 30 * 60)
        activity.idle = 30 * 60
        store.checkReturnNudge()
        XCTAssertEqual(notifier.returnNudgeCount, 0)
    }

    func testOncePerGap() {
        let (store, clock, notifier, activity) = makeStore()
        completeFocus(store, clock)

        clock.advance(by: 13 * 60)
        activity.idle = 5
        store.checkReturnNudge()
        XCTAssertEqual(notifier.returnNudgeCount, 1)

        clock.advance(by: 60)
        store.checkReturnNudge()
        XCTAssertEqual(notifier.returnNudgeCount, 1)
    }

    func testNewFocusRearms() {
        let (store, clock, notifier, activity) = makeStore()
        completeFocus(store, clock)

        clock.advance(by: 13 * 60)
        activity.idle = 5
        store.checkReturnNudge()
        XCTAssertEqual(notifier.returnNudgeCount, 1)

        // Start the suggested round, finish it, and the next gap nudges again.
        store.startNext()
        store.skip()
        store.start(.focus)
        clock.advance(by: 25 * 60 + 1)
        store.tick()
        clock.advance(by: 13 * 60)
        store.checkReturnNudge()
        XCTAssertEqual(notifier.returnNudgeCount, 2)
    }

    func testDisabledNeverFires() {
        let (store, clock, notifier, activity) = makeStore()
        completeFocus(store, clock)
        var settings = store.settings
        settings.returnNudgeEnabled = false
        store.updateSettings(settings)

        clock.advance(by: 30 * 60)
        activity.idle = 5
        store.checkReturnNudge()
        XCTAssertEqual(notifier.returnNudgeCount, 0)
        XCTAssertFalse(store.isReturnNudgeTimerRunning)
    }

    func testBreakEndDoesNotArm() {
        let (store, clock, notifier, activity) = makeStore()
        store.updateSettings(FocusSettings(focusMinutes: 25, shortBreakMinutes: 5))
        store.start(.shortBreak)
        clock.advance(by: 5 * 60 + 1)
        store.tick()

        clock.advance(by: 30 * 60)
        activity.idle = 5
        store.checkReturnNudge()
        XCTAssertEqual(notifier.returnNudgeCount, 0)
    }

    func testManualStartDisarms() {
        let (store, clock, notifier, activity) = makeStore()
        completeFocus(store, clock)

        clock.advance(by: 13 * 60)
        store.start(.focus)
        activity.idle = 5
        store.checkReturnNudge()
        XCTAssertEqual(notifier.returnNudgeCount, 0)
        XCTAssertGreaterThanOrEqual(notifier.returnNudgeCancelledCount, 1)
    }

    func testActionStartsFocusSilently() {
        let (store, clock, notifier, _) = makeStore()
        store.updateSettings(FocusSettings(focusMinutes: 25, shortBreakMinutes: 0))
        store.start(.focus)
        clock.advance(by: 25 * 60 + 1)
        store.tick()
        XCTAssertEqual(store.pendingNext, .focus)

        store.handleReturnNudgeAction()
        XCTAssertEqual(store.activePhase, .focus)
        XCTAssertGreaterThanOrEqual(notifier.returnNudgeCancelledCount, 1)
    }

    func testNudgeStateSurvivesRelaunch() {
        let directory = freshDirectory()
        let clock = ManualFocusClock()
        clock.nowDate = Calendar.current.date(
            bySettingHour: 12, minute: 0, second: 0, of: clock.nowDate
        ) ?? clock.nowDate
        let notifier = FakeFocusNotifier()
        let activity = FakeFocusActivity()
        let (store, _, _, _) = makeStore(
            in: directory, clock: clock, notifier: notifier, activity: activity)
        completeFocus(store, clock)
        clock.advance(by: 13 * 60)
        activity.idle = 5
        store.checkReturnNudge()
        XCTAssertEqual(notifier.returnNudgeCount, 1)

        // Relaunch into the same gap: already nudged, stays quiet.
        let revived = FocusStore(
            in: directory, clock: clock, notifier: notifier, activity: activity)
        revived.checkReturnNudge()
        XCTAssertEqual(notifier.returnNudgeCount, 1)
    }

    func testExpiredGapStaysQuiet() {
        let (store, clock, notifier, activity) = makeStore()
        completeFocus(store, clock)

        // Past the delay plus the expiry, the moment has passed, not waited.
        clock.advance(by: TimeInterval(12 * 60) + FocusStore.returnNudgeExpiry + 60)
        activity.idle = 5
        store.checkReturnNudge()
        XCTAssertEqual(notifier.returnNudgeCount, 0)
        XCTAssertFalse(store.isReturnNudgeTimerRunning)
    }

    func testDeniedDoesNotConsumeTheGap() async {
        let (store, clock, notifier, activity) = makeStore()
        notifier.statusToReport = .denied
        await store.refreshNotificationStatus()
        completeFocus(store, clock)

        clock.advance(by: 13 * 60)
        activity.idle = 5
        store.checkReturnNudge()
        XCTAssertEqual(notifier.returnNudgeCount, 0)
        // Still armed: granting later can still nudge this gap.
        XCTAssertTrue(store.isReturnNudgeArmed)

        notifier.statusToReport = .authorized
        await store.refreshNotificationStatus()
        store.checkReturnNudge()
        XCTAssertEqual(notifier.returnNudgeCount, 1)
    }

    func testActionStartsWaitingBreakFirst() {
        let (store, clock, _, _) = makeStore()
        completeFocus(store, clock)
        XCTAssertEqual(store.pendingNext, .shortBreak)

        store.handleReturnNudgeAction()
        XCTAssertEqual(store.activePhase, .shortBreak)
    }
    func testOldSettingsDecodeWithNudgeDefaults() throws {
        let data = """
            {"focusMinutes":25,"shortBreakMinutes":5}
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FocusSettings.self, from: data)
        XCTAssertTrue(decoded.returnNudgeEnabled)
        XCTAssertEqual(decoded.returnNudgeMinutes, 12)
    }

    func testNudgeDelayClamps() {
        let (store, _, _, _) = makeStore()
        store.updateSettings(FocusSettings(
            focusMinutes: 25, shortBreakMinutes: 5,
            returnNudgeEnabled: true, returnNudgeMinutes: 500))
        XCTAssertEqual(store.settings.returnNudgeMinutes, 60)
    }
}
