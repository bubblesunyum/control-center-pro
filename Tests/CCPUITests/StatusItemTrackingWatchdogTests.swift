// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import XCTest
@testable import CCPUI

/// The lost-mouse-up rescue: a button tracking loop that never sees its
/// release hangs the main thread, and local monitors never see events a
/// tracking loop consumes — so the watchdog polls the physical button while
/// the run loop says tracking, and posts one synthetic mouse-up after three
/// consecutive button-up ticks. These prove the decision matrix against fakes:
/// which downs arm, what each tick does, and that nothing is left installed.
@MainActor
final class StatusItemTrackingWatchdogTests: XCTestCase {
    private var seam: FakeTrackingSeam!
    private var watchdog: StatusItemTrackingWatchdog!
    private var menuAssigned = false
    private var statusEvent = true

    override func setUp() {
        super.setUp()
        let fake = FakeTrackingSeam()
        seam = fake
        menuAssigned = false
        statusEvent = true
        watchdog = StatusItemTrackingWatchdog(
            seam: fake.interface,
            hasMenu: { [weak self] in self?.menuAssigned ?? true },
            isStatusEvent: { [weak self] _ in self?.statusEvent ?? false }
        )
    }

    override func tearDown() {
        watchdog.stop()
        watchdog = nil
        super.tearDown()
    }

    func testStartInstallsOneMonitorAndStopRemovesIt() {
        watchdog.start()
        XCTAssertEqual(seam.installedMonitors, 1)

        watchdog.stop()
        XCTAssertEqual(seam.installedMonitors, 0)
        XCTAssertEqual(seam.installedTimers, 0)
    }

    func testStartingTwiceInstallsOneMonitor() {
        watchdog.start()
        watchdog.start()

        XCTAssertEqual(seam.installedMonitors, 1)
    }

    func testDownOnStatusWindowArmsTheTimer() {
        watchdog.start()

        XCTAssertNotNil(seam.sendDown(), "the click still reaches the button")
        XCTAssertTrue(watchdog.isArmed)
        XCTAssertEqual(seam.installedTimers, 1)
        XCTAssertNotNil(seam.timerTick)
        XCTAssertEqual(seam.lastInterval ?? -1, 0.1, accuracy: 0.001)
    }

    func testSecondDownWhileArmedSchedulesNoSecondTimer() {
        watchdog.start()

        seam.sendDown()
        seam.sendDown()

        XCTAssertEqual(seam.scheduledTimers, 1)
    }

    func testDownElsewhereDoesNotArm() {
        statusEvent = false
        watchdog.start()

        seam.sendDown()

        XCTAssertFalse(watchdog.isArmed)
        XCTAssertEqual(seam.installedTimers, 0)
    }

    func testDownWhileMenuAssignedDoesNotArm() {
        menuAssigned = true
        watchdog.start()

        seam.sendDown()

        XCTAssertFalse(watchdog.isArmed)
        XCTAssertEqual(seam.installedTimers, 0)
    }

    /// The ordinary click: tracking ended on its own, so the next tick reads
    /// a normal mode and stands down with nothing posted.
    func testTrackingEndedDisarmsWithoutPosting() {
        watchdog.start()
        seam.sendDown()
        XCTAssertTrue(watchdog.isArmed)

        seam.runLoopMode = .default
        seam.buttonDown = false
        watchdog.tick()

        XCTAssertFalse(watchdog.isArmed)
        XCTAssertEqual(seam.installedTimers, 0)
        XCTAssertEqual(seam.postedMouseUps, 0)
    }

    /// The stuck loop: button physically up for three straight tracking ticks
    /// posts exactly one rescue, then stands down — a fourth tick posts
    /// nothing more.
    func testThreeButtonUpTicksPostOneRescue() {
        watchdog.start()
        seam.sendDown()
        seam.runLoopMode = .eventTracking
        seam.buttonDown = false

        watchdog.tick()
        watchdog.tick()
        XCTAssertEqual(seam.postedMouseUps, 0, "two silent ticks post nothing")
        XCTAssertTrue(watchdog.isArmed)

        watchdog.tick()
        XCTAssertEqual(seam.postedMouseUps, 1, "the third consecutive button-up tick rescues the loop")
        XCTAssertFalse(watchdog.isArmed, "posts once, then stands down")
        XCTAssertEqual(seam.installedTimers, 0)

        watchdog.tick()
        XCTAssertEqual(seam.postedMouseUps, 1)
    }

    func testHeldButtonNeverPosts() {
        watchdog.start()
        seam.sendDown()
        seam.runLoopMode = .eventTracking
        seam.buttonDown = true

        for _ in 0..<10 { watchdog.tick() }

        XCTAssertEqual(seam.postedMouseUps, 0)
        XCTAssertTrue(watchdog.isArmed, "still watching while held")
    }

    /// A press in the middle breaks the run: only three *consecutive* ups
    /// rescue, so a held tick between two pairs posts once, at the end.
    func testInterruptedUpsResetTheCount() {
        watchdog.start()
        seam.sendDown()
        seam.runLoopMode = .eventTracking
        seam.buttonDown = false

        watchdog.tick()
        watchdog.tick()
        seam.buttonDown = true
        watchdog.tick()
        seam.buttonDown = false
        watchdog.tick()
        watchdog.tick()
        XCTAssertEqual(seam.postedMouseUps, 0)

        watchdog.tick()
        XCTAssertEqual(seam.postedMouseUps, 1)
    }

    func testStopWhileArmedRemovesTimerAndMonitor() {
        watchdog.start()
        seam.sendDown()
        XCTAssertTrue(watchdog.isArmed)

        watchdog.stop()

        XCTAssertFalse(watchdog.isArmed)
        XCTAssertEqual(seam.installedTimers, 0)
        XCTAssertEqual(seam.installedMonitors, 0)
        XCTAssertEqual(seam.postedMouseUps, 0)
    }
}

/// Stands in for the watchdog's AppKit boundary: records which watches were
/// installed and how many rescues were posted, with scripted button and
/// run-loop-mode reads. The timer's tick closure is captured but never fired
/// here — tests drive `tick()` directly, the way the overlay tests drive
/// `watchdogFired()`, so every poll is synchronous.
@MainActor
private final class FakeTrackingSeam {
    private(set) var addedMonitors = 0
    private(set) var removedMonitors = 0
    private(set) var scheduledTimers = 0
    private(set) var invalidatedTimers = 0
    private(set) var postedMouseUps = 0
    private(set) var lastInterval: TimeInterval?
    private var liveMonitors: Set<Int> = []
    private var liveTimers: Set<Int> = []
    private var nextToken = 0

    var monitorHandler: ((NSEvent) -> NSEvent?)?
    var timerTick: (() -> Void)?
    var buttonDown = false
    var runLoopMode: RunLoop.Mode? = .default

    var installedMonitors: Int { liveMonitors.count }
    var installedTimers: Int { liveTimers.count }

    var interface: StatusItemTrackingSeam {
        StatusItemTrackingSeam(
            addMonitor: { [self] _, handler in
                monitorHandler = handler
                return monitorToken()
            },
            removeMonitor: { [self] handle in
                guard let token = handle as? Int else { return XCTFail("not one of ours") }
                liveMonitors.remove(token)
                removedMonitors += 1
            },
            scheduleTimer: { [self] interval, tick in
                lastInterval = interval
                timerTick = tick
                return timerToken()
            },
            invalidateTimer: { [self] handle in
                guard let token = handle as? Int else { return XCTFail("not one of ours") }
                liveTimers.remove(token)
                invalidatedTimers += 1
            },
            pressedMouseButtons: { [self] in buttonDown ? 1 : 0 },
            currentRunLoopMode: { [self] in runLoopMode },
            postMouseUp: { [self] in postedMouseUps += 1 }
        )
    }

    private func monitorToken() -> Any {
        nextToken += 1
        addedMonitors += 1
        liveMonitors.insert(nextToken)
        return nextToken
    }

    private func timerToken() -> Any {
        nextToken += 1
        scheduledTimers += 1
        liveTimers.insert(nextToken)
        return nextToken
    }

    @discardableResult
    func sendDown() -> NSEvent? {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!
        return monitorHandler?(event)
    }
}
