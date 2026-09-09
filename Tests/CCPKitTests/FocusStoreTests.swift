// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
@testable import CCPKit
import XCTest

final class ManualFocusClock: FocusClock, @unchecked Sendable {
    // Unchecked because tests drive the clock from the main actor only; the
    // protocol's Sendable bound is for the store holding it across isolation.
    var nowDate = Date()
    func now() -> Date { nowDate }
    func advance(by interval: TimeInterval) { nowDate = nowDate.addingTimeInterval(interval) }
}

final class FakeFocusNotifier: FocusNotifier, @unchecked Sendable {
    // Unchecked for the same reason: mutated on the main actor by tests and
    // read back on the main actor, never raced.
    struct Scheduled: Equatable {
        let title: String
        let body: String
        let at: Date
    }

    var statusToReport: FocusNotificationStatus = .authorized
    var requestResult = true
    private(set) var scheduled: [Scheduled] = []
    private(set) var cancelledCount = 0
    private(set) var chimeCount = 0
    private(set) var authorizationRequests = 0

    func currentStatus() async -> FocusNotificationStatus { statusToReport }

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        statusToReport = requestResult ? .authorized : .denied
        return requestResult
    }

    func schedule(title: String, body: String, at: Date) {
        scheduled.append(Scheduled(title: title, body: body, at: at))
    }

    func cancelScheduled() { cancelledCount += 1 }
    func chime() { chimeCount += 1 }
}

@MainActor
final class FocusStoreTests: XCTestCase {
    private func freshDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(
        in directory: URL? = nil,
        clock: ManualFocusClock? = nil,
        notifier: FakeFocusNotifier? = nil
    ) -> (FocusStore, ManualFocusClock, FakeFocusNotifier) {
        let clock = clock ?? ManualFocusClock()
        let notifier = notifier ?? FakeFocusNotifier()
        let store = FocusStore(
            in: directory ?? freshDirectory(), clock: clock, notifier: notifier)
        return (store, clock, notifier)
    }

    // MARK: - Starting

    func testStartFocusSetsDeadlineAndSchedulesNotification() {
        let (store, clock, notifier) = makeStore()
        store.updateSettings(FocusSettings(
            focusMinutes: 25, shortBreakMinutes: 5, breaksEnabled: true))

        store.start(.focus)

        XCTAssertEqual(store.activePhase, .focus)
        XCTAssertEqual(store.endsAt, clock.nowDate.addingTimeInterval(25 * 60))
        XCTAssertEqual(store.remaining ?? -1, 25 * 60, accuracy: 0.5)
        XCTAssertEqual(notifier.scheduled.count, 1)
        XCTAssertEqual(notifier.scheduled[0].at, store.endsAt)
        XCTAssertFalse(notifier.scheduled[0].title.isEmpty)
    }

    func testStartWhileRunningIsIgnored() {
        let (store, _, notifier) = makeStore()

        store.start(.focus)
        let deadline = store.endsAt
        store.start(.shortBreak)

        XCTAssertEqual(store.activePhase, .focus)
        XCTAssertEqual(store.endsAt, deadline)
        XCTAssertEqual(notifier.scheduled.count, 1)
    }

    // MARK: - Completing

    func testFocusDeadlineCompletesAndWaitsOnShortBreak() {
        let (store, clock, notifier) = makeStore()
        store.panelOpened()
        store.start(.focus)

        clock.advance(by: 25 * 60 + 1)
        store.tick()

        XCTAssertNil(store.activePhase)
        XCTAssertEqual(store.pendingNext, .shortBreak)
        XCTAssertEqual(store.focusStreak, 1)
        XCTAssertEqual(store.completedFocusToday, 1)
        XCTAssertEqual(notifier.chimeCount, 1)
        XCTAssertGreaterThanOrEqual(notifier.cancelledCount, 1)
        store.panelClosed()
    }

    func testChimeWhenPanelClosed() {
        // The chime is the store's own sound, separate from the scheduled
        // notification — a shut panel still sounds the round's end.
        let (store, clock, notifier) = makeStore()
        store.start(.focus)

        clock.advance(by: 25 * 60 + 1)
        store.tick()

        XCTAssertEqual(store.pendingNext, .shortBreak)
        XCTAssertEqual(notifier.chimeCount, 1)
    }

    func testBreakCompletionWaitsOnFocus() {
        let (store, clock, _) = makeStore()
        store.start(.shortBreak)

        clock.advance(by: 5 * 60 + 1)
        store.tick()

        XCTAssertEqual(store.pendingNext, .focus)
        XCTAssertEqual(store.focusStreak, 0)
        XCTAssertEqual(store.completedFocusToday, 0)
    }

    func testFocusBreakCycleRepeats() {
        let (store, clock, _) = makeStore()
        store.updateSettings(FocusSettings(
            focusMinutes: 25, shortBreakMinutes: 5, breaksEnabled: true))

        for round in 1...3 {
            store.start(.focus)
            clock.advance(by: 25 * 60 + 1)
            store.tick()
            XCTAssertEqual(store.pendingNext, .shortBreak, "round \(round)")
            XCTAssertEqual(store.focusStreak, round)
            store.startNext()
            clock.advance(by: 5 * 60 + 1)
            store.tick()
            XCTAssertEqual(store.pendingNext, .focus)
        }
    }

    func testBreaksDisabledCyclesFocusToFocus() {
        let (store, clock, notifier) = makeStore()
        store.updateSettings(FocusSettings(
            focusMinutes: 25, shortBreakMinutes: 5, breaksEnabled: false))

        store.start(.focus)
        clock.advance(by: 25 * 60 + 1)
        store.tick()

        // The between-phase stop stays — only the rest goes.
        XCTAssertEqual(store.pendingNext, .focus)
        XCTAssertEqual(store.focusStreak, 1)
        XCTAssertEqual(notifier.chimeCount, 1)

        store.startNext()
        XCTAssertEqual(store.activePhase, .focus)
    }

    func testSkipWithBreaksDisabledWaitsOnFocus() {
        let (store, _, _) = makeStore()
        store.updateSettings(FocusSettings(
            focusMinutes: 25, shortBreakMinutes: 5, breaksEnabled: false))
        store.start(.focus)

        store.skip()

        XCTAssertEqual(store.pendingNext, .focus)
        XCTAssertEqual(store.focusStreak, 0)
    }

    func testDisablingBreaksWhileWaitingRepointsAtFocus() {
        let (store, clock, _) = makeStore()
        store.start(.focus)
        clock.advance(by: 25 * 60 + 1)
        store.tick()
        XCTAssertEqual(store.pendingNext, .shortBreak)

        var next = store.settings
        next.breaksEnabled = false
        store.updateSettings(next)

        XCTAssertEqual(store.pendingNext, .focus)
        store.startNext()
        XCTAssertEqual(store.activePhase, .focus)
    }

    // MARK: - Pause / resume

    func testPauseFreezesRemainingAndResumeExtendsDeadline() {
        let (store, clock, notifier) = makeStore()
        store.start(.focus)

        clock.advance(by: 60)
        store.pause()

        XCTAssertTrue(store.isPaused)
        XCTAssertNil(store.endsAt)
        XCTAssertEqual(store.pausedRemaining ?? -1, 24 * 60, accuracy: 0.5)

        // Time passing while paused changes nothing.
        clock.advance(by: 10 * 60)
        store.tick()
        XCTAssertTrue(store.isPaused)
        XCTAssertEqual(store.pausedRemaining ?? -1, 24 * 60, accuracy: 0.5)

        let cancels = notifier.cancelledCount
        XCTAssertGreaterThanOrEqual(cancels, 1)

        store.resume()
        XCTAssertTrue(store.isRunning)
        XCTAssertEqual(store.endsAt, clock.nowDate.addingTimeInterval(24 * 60))
        XCTAssertEqual(notifier.scheduled.count, 2)
    }

    // MARK: - Reset / skip

    func testResetAbandonsToIdleAndBreaksStreak() {
        let (store, clock, _) = makeStore()
        store.start(.focus)
        clock.advance(by: 25 * 60 + 1)
        store.tick()
        store.startNext()
        clock.advance(by: 60)
        store.start(.focus) // ignored while a break runs
        store.reset()

        // Resetting a break goes idle but keeps the streak — breaks never
        // break the chain.
        XCTAssertTrue(store.isIdle)
        XCTAssertEqual(store.focusStreak, 1)
        // One completed focus, one abandoned break.
        XCTAssertEqual(store.completedFocusToday, 1)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertFalse(store.sessions.allSatisfy(\.completed))

        // Resetting a focus breaks it.
        store.start(.focus)
        store.reset()
        XCTAssertTrue(store.isIdle)
        XCTAssertEqual(store.focusStreak, 0)
    }

    func testSkipFocusWaitsOnShortBreakWithoutStreak() {
        let (store, clock, _) = makeStore()
        store.start(.focus)
        clock.advance(by: 60)

        store.skip()

        XCTAssertEqual(store.pendingNext, .shortBreak)
        XCTAssertEqual(store.focusStreak, 0)
        XCTAssertEqual(store.completedFocusToday, 0)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertFalse(store.sessions[0].completed)
    }

    // MARK: - Persistence

    func testRestartRestoresRunningPhase() {
        let directory = freshDirectory()
        let clock = ManualFocusClock()
        let (store, _, _) = makeStore(in: directory, clock: clock)
        store.start(.focus)
        let deadline = store.endsAt

        let revived = FocusStore(in: directory, clock: clock)

        XCTAssertEqual(revived.activePhase, .focus)
        XCTAssertEqual(revived.endsAt, deadline)
        XCTAssertEqual(revived.remaining ?? -1, 25 * 60, accuracy: 0.5)
    }

    func testOverdueDeadlineReconcilesSilentlyOnLaunch() {
        let directory = freshDirectory()
        let clock = ManualFocusClock()
        let notifier = FakeFocusNotifier()
        let (store, _, _) = makeStore(in: directory, clock: clock, notifier: notifier)
        store.start(.focus)

        clock.advance(by: 25 * 60 + 1)
        let relaunched = FocusStore(in: directory, clock: clock, notifier: notifier)

        // The notification already fired while quit — land finished, stay quiet.
        XCTAssertEqual(relaunched.pendingNext, .shortBreak)
        XCTAssertEqual(relaunched.focusStreak, 1)
        XCTAssertEqual(notifier.chimeCount, 0)
    }

    // MARK: - Settings

    func testSettingsClampToStepperRanges() {
        let (store, _, _) = makeStore()
        store.updateSettings(FocusSettings(
            focusMinutes: 500, shortBreakMinutes: 0, breaksEnabled: false))

        XCTAssertEqual(store.settings.focusMinutes, 120)
        XCTAssertEqual(store.settings.shortBreakMinutes, 1)
        XCTAssertFalse(store.settings.breaksEnabled)
    }

    func testSettingsPersistAndLeaveRunningDeadlineAlone() {
        let directory = freshDirectory()
        let (store, clock, _) = makeStore(in: directory)
        store.start(.focus)
        let deadline = store.endsAt

        store.updateSettings(FocusSettings(
            focusMinutes: 50, shortBreakMinutes: 10, breaksEnabled: false))

        XCTAssertEqual(store.endsAt, deadline)

        let revived = FocusStore(in: directory, clock: clock)
        XCTAssertEqual(revived.settings.focusMinutes, 50)
        XCTAssertFalse(revived.settings.breaksEnabled)
    }

    // MARK: - Legacy files

    func testLegacySettingsDecodeWithDefaults() throws {
        // An old focus.json carries long-break keys and no breaks switch —
        // it still reads, leftovers ignored, switch on.
        let data = """
            {"focusMinutes":25,"shortBreakMinutes":5,"longBreakMinutes":15,"roundsBeforeLongBreak":4}
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FocusSettings.self, from: data)

        XCTAssertEqual(decoded.focusMinutes, 25)
        XCTAssertEqual(decoded.shortBreakMinutes, 5)
        XCTAssertTrue(decoded.breaksEnabled)
    }

    func testLegacyLongBreakPhaseDecodesAsBreak() throws {
        let data = "\"longBreak\"".data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(FocusPhase.self, from: data), .shortBreak)
    }

    // MARK: - Notification authorization

    func testFirstStartRequestsAuthorization() async {
        let notifier = FakeFocusNotifier()
        notifier.statusToReport = .notDetermined
        let (store, _, _) = makeStore(notifier: notifier)
        await store.refreshNotificationStatus()
        XCTAssertEqual(store.notificationStatus, .notDetermined)

        store.start(.focus)

        _ = await becomesTrue { notifier.authorizationRequests >= 1 }
        _ = await becomesTrue { store.notificationStatus == .authorized }
        XCTAssertEqual(notifier.authorizationRequests, 1)
    }

    func testNoAutoRequestOnceDetermined() async {
        let notifier = FakeFocusNotifier()
        notifier.statusToReport = .denied
        let (store, _, _) = makeStore(notifier: notifier)
        await store.refreshNotificationStatus()

        store.start(.focus)

        XCTAssertEqual(notifier.authorizationRequests, 0)
        XCTAssertEqual(store.notificationStatus, .denied)
    }

    // MARK: - Overdue actions

    func testPauseAfterDeadlineCompletesInsteadOfWedging() {
        let (store, clock, _) = makeStore()
        store.panelOpened()
        store.start(.focus)

        // The tick hasn't run yet, but the deadline has passed.
        clock.advance(by: 25 * 60 + 1)
        store.pause()

        XCTAssertEqual(store.pendingNext, .shortBreak)
        XCTAssertEqual(store.focusStreak, 1)
        XCTAssertEqual(store.completedFocusToday, 1)
        XCTAssertFalse(store.isPaused)
        store.panelClosed()
    }

    func testResetAfterDeadlineKeepsTheCompletion() {
        let (store, clock, _) = makeStore()
        store.start(.focus)

        clock.advance(by: 25 * 60 + 1)
        store.reset()

        // The stretch completed first, so there is nothing active to abandon.
        XCTAssertEqual(store.pendingNext, .shortBreak)
        XCTAssertEqual(store.completedFocusToday, 1)
        XCTAssertEqual(store.focusStreak, 1)
    }

    func testSkipAfterDeadlineKeepsTheCompletion() {
        let (store, clock, _) = makeStore()
        store.start(.focus)

        clock.advance(by: 25 * 60 + 1)
        store.skip()

        XCTAssertEqual(store.pendingNext, .shortBreak)
        XCTAssertEqual(store.completedFocusToday, 1)
    }

    // MARK: - Freshness

    func testMutationsSyncThePublishedClock() {
        let (store, clock, _) = makeStore()
        store.panelOpened()
        // Ten idle minutes with no ticker: `now` is stale.
        clock.advance(by: 10 * 60)

        store.start(.focus)

        // The card reads remaining(at: now) — a stale now would show 35:00.
        XCTAssertEqual(store.now, clock.nowDate)
        XCTAssertEqual(store.remaining(at: store.now) ?? -1, 25 * 60, accuracy: 0.5)
        store.panelClosed()
    }

    // MARK: - Ticker lifecycle

    func testTickerRunsOnlyWhilePanelIsOpen() {
        let (store, _, _) = makeStore()

        store.start(.focus)
        XCTAssertFalse(store.isTickerRunning)

        store.panelOpened()
        XCTAssertTrue(store.isTickerRunning)

        store.panelClosed()
        XCTAssertFalse(store.isTickerRunning)
    }

    func testRetentionSweepSparesTheOpenSession() {
        let (store, clock, _) = makeStore()
        store.start(.focus)
        store.pause()

        // A pause outliving the 90-day retention window.
        clock.advance(by: 91 * 24 * 60 * 60)
        // Any save runs the sweep — re-saving the untouched settings will do.
        store.updateSettings(store.settings)

        // Still there: the open stretch is spared the sweep.
        XCTAssertEqual(store.sessions.count, 1)
        store.reset()
        // Closing clears the spare, so the 91-day-old attempt falls off —
        // count 0 is what proves the close ran rather than no-op'd.
        XCTAssertEqual(store.sessions.count, 0)
        XCTAssertTrue(store.isIdle)
    }

    // MARK: - Formatting

    func testMmss() {
        XCTAssertEqual(FocusStore.mmss(25 * 60), "25:00")
        XCTAssertEqual(FocusStore.mmss(61), "1:01")
        XCTAssertEqual(FocusStore.mmss(5), "0:05")
        XCTAssertEqual(FocusStore.mmss(0), "0:00")
    }

    func testRemainingNilWhenIdle() {
        let (store, _, _) = makeStore()
        XCTAssertNil(store.remaining(at: Date()))
    }
}
