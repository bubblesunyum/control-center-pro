// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import Observation

/// The Focus widget's model, shared so the menu-bar countdown reads the same
/// truth as the card.
///
/// Deadline-based: a running phase is `activePhase + endsAt`, never a counter.
/// While the panel is open a 1s ticker refreshes the countdown and notices
/// the deadline passing; with the panel shut nothing ticks — a phase that
/// ends there is announced by its scheduled notification plus the store's own
/// chime, and reopening recomputes from the clock. The menu-bar countdown is
/// the status item's own timer reading this same truth, so a shut panel with
/// no session running costs nothing.
@MainActor
@Observable
public final class FocusStore {
    public static let shared = FocusStore()

    public private(set) var settings: FocusSettings
    public private(set) var activePhase: FocusPhase?
    public private(set) var endsAt: Date?
    public private(set) var pausedRemaining: TimeInterval?
    /// The phase a finished stretch is waiting on. Non-nil only between
    /// phases — transitions are manual, never automatic.
    public private(set) var pendingNext: FocusPhase?
    /// Consecutive completed focuses. Nothing reads it yet — no dots, no
    /// long break — but the count stays warm for whatever comes next.
    /// A skipped or reset focus breaks the chain; breaks never do.
    public private(set) var focusStreak: Int
    public private(set) var sessions: [FocusSession]
    /// The countdown's clock. Refreshed by the ticker while open and by every
    /// mutation, so a readout never renders a stale `now`.
    public private(set) var now = Date()
    public private(set) var notificationStatus: FocusNotificationStatus

    @ObservationIgnored private let clock: FocusClock
    @ObservationIgnored private let notifier: FocusNotifier
    @ObservationIgnored private let activity: FocusActivitySource
    @ObservationIgnored private let file: JSONFileStore<FocusPersisted>
    @ObservationIgnored private var openSessionID: UUID?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var returnNudgeTimer: Timer?
    @ObservationIgnored private var panelOpenCount = 0
    /// Which completed focus the nudge already fired for. Once per gap.
    @ObservationIgnored private var lastNudgeSessionID: UUID?

    /// Sessions older than this fall off the log on save — history, not archive.
    static let sessionRetention: TimeInterval = 90 * 24 * 60 * 60
    static let sessionCap = 2000
    /// How often the return watch polls once a focus gap is open, and what
    /// counts as "just used the Mac". 15s each for the trial.
    static let returnNudgePollInterval: TimeInterval = 15
    static let returnNudgeActivityThreshold: TimeInterval = 15

    public convenience init() {
        self.init(in: .applicationSupport, notifier: LiveFocusNotifier())
    }

    init(
        in directory: URL,
        clock: FocusClock = SystemFocusClock(),
        // Noop by default on purpose: UNUserNotificationCenter.current() has
        // no bundle under xctest and traps, so only the shipped shared
        // instance opts into the live notifier. Tests hand a fake.
        notifier: FocusNotifier = NoopFocusNotifier(),
        activity: FocusActivitySource = LiveFocusActivitySource()
    ) {
        self.clock = clock
        self.notifier = notifier
        self.activity = activity
        self.file = JSONFileStore(filename: "focus.json", default: .empty, in: directory)
        let saved = file.load()
        self.settings = saved.settings.clamped
        self.sessions = saved.sessions
        self.activePhase = saved.activePhase
        self.endsAt = saved.endsAt
        self.pausedRemaining = saved.pausedRemaining
        self.pendingNext = saved.pendingNext
        self.focusStreak = saved.focusStreak
        self.openSessionID = saved.openSessionID
        self.lastNudgeSessionID = saved.lastNudgeSessionID
        self.notificationStatus = .unknown
        Task { await refreshNotificationStatus() }
        // A deadline that passed while quit already fired its notification —
        // land in the finished state silently rather than chiming at launch.
        reconcile(announce: false)
        ensureTimers()
    }

    deinit {
        ticker?.invalidate()
        returnNudgeTimer?.invalidate()
    }

    // MARK: - Derived

    public var isRunning: Bool { activePhase != nil && pausedRemaining == nil }
    public var isPaused: Bool { activePhase != nil && pausedRemaining != nil }
    public var isIdle: Bool { activePhase == nil && pendingNext == nil }
    public var isAwaitingNext: Bool { activePhase == nil && pendingNext != nil }

    public func remaining(at date: Date) -> TimeInterval? {
        if let endsAt, pausedRemaining == nil {
            return max(endsAt.timeIntervalSince(date), 0)
        }
        return pausedRemaining
    }

    public var remaining: TimeInterval? { remaining(at: clock.now()) }

    public func duration(of phase: FocusPhase) -> TimeInterval {
        TimeInterval(settings.minutes(for: phase) * 60)
    }

    /// 0…1 of the active phase elapsed. Nil when nothing runs.
    public func fractionElapsed(at date: Date) -> Double? {
        guard let phase = activePhase, let remaining = remaining(at: date) else { return nil }
        let total = duration(of: phase)
        guard total > 0 else { return nil }
        return min(max((total - remaining) / total, 0), 1)
    }

    /// How many focuses completed since the day turned over. The day turns
    /// over at 6AM, not midnight — a round finished after midnight still
    /// belongs to yesterday.
    public var completedFocusToday: Int {
        let now = clock.now()
        return sessions.filter {
            $0.kind == .focus && $0.completed
                && $0.endedAt.map({ isSameFocusDay($0, as: now) }) == true
        }.count
    }

    /// The hour the day turns over for the count above.
    static let dayTurnoverHour = 6

    private func isSameFocusDay(_ date: Date, as now: Date) -> Bool {
        let offset = -Double(Self.dayTurnoverHour) * 3600
        return Calendar.current.isDate(
            date.addingTimeInterval(offset),
            inSameDayAs: now.addingTimeInterval(offset)
        )
    }

    /// mm:ss, shared by the card and the menu-bar countdown.
    public static func mmss(_ interval: TimeInterval) -> String {
        let total = max(Int(interval.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Panel lifecycle

    /// The widget forwards activate()/deactivate() here. A transition the
    /// ticker missed while shut lands silently — its notification and chime
    /// already fired — rather than sounding at open.
    public func panelOpened() {
        panelOpenCount += 1
        now = clock.now()
        reconcile(announce: false)
        ensureTicker()
        Task { await refreshNotificationStatus() }
    }

    public func panelClosed() {
        panelOpenCount = max(panelOpenCount - 1, 0)
        ensureTicker()
    }

    // MARK: - Actions

    /// Begin a phase. Only from idle or between phases — starting over a
    /// running stretch is the reset button's job, not this one's.
    public func start(_ phase: FocusPhase) {
        guard activePhase == nil else { return }
        now = clock.now()
        let startedAt = now
        activePhase = phase
        endsAt = startedAt.addingTimeInterval(duration(of: phase))
        pausedRemaining = nil
        pendingNext = nil
        let session = FocusSession(kind: phase, startedAt: startedAt)
        sessions.append(session)
        openSessionID = session.id
        scheduleNotification(for: phase, endingAt: endsAt!)
        notifier.cancelReturnNudge()
        maybeRequestAuthorization()
        save()
        ensureTimers()
    }

    public func startNext() {
        guard let next = pendingNext else { return }
        start(next)
    }

    public func pause() {
        // An overdue deadline completes first — pausing a finished stretch
        // would wedge it at 0:00 with the completion never recorded.
        reconcile(announce: true)
        guard let endsAt, pausedRemaining == nil else { return }
        now = clock.now()
        pausedRemaining = max(endsAt.timeIntervalSince(now), 0)
        self.endsAt = nil
        notifier.cancelScheduled()
        save()
        ensureTimers()
    }

    public func resume() {
        guard activePhase != nil, let paused = pausedRemaining else { return }
        now = clock.now()
        let deadline = now.addingTimeInterval(paused)
        endsAt = deadline
        pausedRemaining = nil
        scheduleNotification(for: activePhase!, endingAt: deadline)
        save()
        ensureTimers()
    }

    /// Abandon the active stretch and go idle. The attempt stays in the log
    /// as uncompleted; an abandoned focus breaks the streak.
    public func reset() {
        reconcile(announce: true)
        guard activePhase != nil else { return }
        now = clock.now()
        closeOpenSession(completed: false, at: now)
        if activePhase == .focus { focusStreak = 0 }
        activePhase = nil
        endsAt = nil
        pausedRemaining = nil
        pendingNext = nil
        notifier.cancelScheduled()
        notifier.cancelReturnNudge()
        save()
        ensureTimers()
    }

    /// Abandon the active stretch but keep the cycle going — land waiting on
    /// the phase that follows. With breaks off a skipped focus just waits on
    /// another focus.
    public func skip() {
        reconcile(announce: true)
        guard let phase = activePhase else { return }
        now = clock.now()
        closeOpenSession(completed: false, at: now)
        if phase == .focus { focusStreak = 0 }
        activePhase = nil
        endsAt = nil
        pausedRemaining = nil
        pendingNext = phase == .focus ? nextAfterFocus() : .focus
        notifier.cancelScheduled()
        notifier.cancelReturnNudge()
        save()
        ensureTimers()
    }

    public func updateSettings(_ next: FocusSettings) {
        settings = next.clamped
        // A pendingNext decided under the old switch goes stale: turning
        // breaks off while waiting on a break must not still offer it.
        if activePhase == nil, !settings.breaksEnabled, pendingNext == .shortBreak {
            pendingNext = .focus
        }
        if !settings.returnNudgeEnabled { notifier.cancelReturnNudge() }
        save()
        ensureTimers()
        // A running phase keeps its deadline — new durations start next phase.
    }

    // MARK: - Notifications

    public func refreshNotificationStatus() async {
        notificationStatus = await notifier.currentStatus()
    }

    /// The inline grant prompt calls this; the first start calls it too,
    /// since tapping Start is the intent the system prompt needs.
    public func requestNotificationAuthorization() async {
        _ = await notifier.requestAuthorization()
        await refreshNotificationStatus()
    }

    private func maybeRequestAuthorization() {
        guard notificationStatus == .unknown || notificationStatus == .notDetermined else { return }
        Task { await requestNotificationAuthorization() }
    }

    // MARK: - Engine

    private func reconcile(announce: Bool) {
        guard let phase = activePhase,
              let endsAt,
              pausedRemaining == nil,
              clock.now() >= endsAt
        else { return }
        closeOpenSession(completed: true, at: endsAt)
        notifier.cancelScheduled()
        if phase == .focus {
            focusStreak += 1
            pendingNext = nextAfterFocus()
        } else {
            pendingNext = .focus
        }
        activePhase = nil
        self.endsAt = nil
        // The chime is the store's own sound, separate from the scheduled
        // notification — it plays wherever the deadline is noticed, panel
        // open or shut. Only the quiet reconciles (launch, panel open) skip
        // it, since those land a finish the user already slept through.
        if announce { notifier.chime() }
        save()
        ensureTimers()
    }

    /// What a finished focus waits on. Breaks off means straight back to
    /// focus — the between-phase stop stays, the rest goes.
    private func nextAfterFocus() -> FocusPhase {
        settings.breaksEnabled ? .shortBreak : .focus
    }

    private func closeOpenSession(completed: Bool, at date: Date) {
        guard let id = openSessionID,
              let index = sessions.firstIndex(where: { $0.id == id })
        else { return }
        sessions[index].endedAt = date
        sessions[index].completed = completed
        openSessionID = nil
    }

    private func scheduleNotification(for phase: FocusPhase, endingAt: Date) {
        let (title, body): (String, String)
        switch phase {
        case .focus:
            title = "Focus complete"
            body = "Time for a break — start it when you're ready."
        case .shortBreak:
            title = "Break over"
            body = "Ready for the next focus stretch?"
        }
        notifier.schedule(title: title, body: body, at: endingAt)
    }

    /// The ticker lives only while a phase runs *and* the panel is open. A
    /// shut panel means no countdown to refresh and no deadline to notice —
    /// the scheduled notification covers the ending — so the app idles at
    /// zero. The menu-bar countdown runs its own timer in the status item.
    private func ensureTicker() {
        if isRunning, panelOpenCount > 0 {
            guard ticker == nil else { return }
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.tick()
                }
            }
        } else {
            ticker?.invalidate()
            ticker = nil
        }
    }

    /// Whether the countdown ticker is currently scheduled. A test seam —
    /// production code never branches on it.
    var isTickerRunning: Bool { ticker != nil }

    /// One tick: refresh the published clock and notice an overdue deadline.
    /// The panel-open timer calls this every second, and so does the
    /// menu-bar countdown's own timer — with the panel shut the store's
    /// ticker is stopped, so without this a deadline that passes unseen
    /// would leave the menu bar wedged at 0:00 until the next panel open.
    /// Tests call it after moving a fake clock, which is what makes deadline
    /// behaviour deterministic.
    public func tick() {
        now = clock.now()
        reconcile(announce: true)
    }

    private func save() {
        let cutoff = clock.now().addingTimeInterval(-Self.sessionRetention)
        // Never sweep the open stretch: a pause can outlive the retention
        // window, and pruning it would orphan openSessionID.
        sessions.removeAll { $0.startedAt < cutoff && $0.id != openSessionID }
        if sessions.count > Self.sessionCap {
            sessions.removeFirst(sessions.count - Self.sessionCap)
        }
        try? file.save(FocusPersisted(
            settings: settings,
            sessions: sessions,
            activePhase: activePhase,
            endsAt: endsAt,
            pausedRemaining: pausedRemaining,
            pendingNext: pendingNext,
            focusStreak: focusStreak,
            openSessionID: openSessionID,
            lastNudgeSessionID: lastNudgeSessionID
        ))
    }

    // MARK: - Return nudge

    /// How long past the delay a gap still counts. A focus finished Friday
    /// must not nudge on Monday: the moment has passed, not waited.
    static let returnNudgeExpiry: TimeInterval = 60 * 60

    /// The gap the watch cares about, if any: notifications on, nothing
    /// running, and the last completed focus not yet nudged for. The nudge
    /// arms on focus end only — a break ending never starts the watch.
    var returnNudgeGap: FocusSession? {
        guard settings.returnNudgeEnabled,
              activePhase == nil, pausedRemaining == nil,
              let last = sessions.last(where: { $0.kind == .focus && $0.completed && $0.endedAt != nil }),
              lastNudgeSessionID != last.id
        else { return nil }
        return last
    }

    /// Whether the watch timer should exist. Broader than armed: it also
    /// covers the delay window, so the fire is noticed without polling
    /// forever — outside a focus gap, or past its expiry, there is no timer.
    var shouldPollReturnNudge: Bool {
        guard let gap = returnNudgeGap, let endedAt = gap.endedAt else { return false }
        let sinceEnd = clock.now().timeIntervalSince(endedAt)
        return sinceEnd <= TimeInterval(settings.returnNudgeMinutes * 60) + Self.returnNudgeExpiry
    }

    /// Ready to fire right now: the delay since the focus end has passed
    /// without the gap expiring.
    var isReturnNudgeArmed: Bool {
        guard shouldPollReturnNudge,
              let endedAt = returnNudgeGap?.endedAt
        else { return false }
        return clock.now().timeIntervalSince(endedAt)
            >= TimeInterval(settings.returnNudgeMinutes * 60)
    }

    /// Whether the return watch timer is currently scheduled. A test seam —
    /// production code never branches on it.
    var isReturnNudgeTimerRunning: Bool { returnNudgeTimer != nil }

    /// Both timers after every transition: the countdown's and the watch's.
    private func ensureTimers() {
        ensureTicker()
        ensureReturnNudgeTimer()
    }

    private func ensureReturnNudgeTimer() {
        guard shouldPollReturnNudge else {
            returnNudgeTimer?.invalidate()
            returnNudgeTimer = nil
            return
        }
        guard returnNudgeTimer == nil else { return }
        returnNudgeTimer = Timer.scheduledTimer(
            withTimeInterval: Self.returnNudgePollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkReturnNudge()
            }
        }
    }

    /// One poll: refresh the clock, and if the delay has passed and the user
    /// was active in the last threshold window, post the nudge exactly once
    /// for this gap. Tests call this after moving the fake clock and activity.
    func checkReturnNudge() {
        now = clock.now()
        guard isReturnNudgeArmed else {
            ensureReturnNudgeTimer()
            return
        }
        // Denied shows nothing, so it must not consume the gap either — the
        // card already offers the way back via its grant row.
        guard notificationStatus != .denied else { return }
        guard activity.idleSeconds() < Self.returnNudgeActivityThreshold else { return }
        notifier.scheduleReturnNudge()
        lastNudgeSessionID = returnNudgeGap?.id
        save()
        ensureReturnNudgeTimer()
    }

    /// The notification's Start action (or a tap on its body). Silent: the
    /// round begins whether the panel is open or not, and the nudge is
    /// withdrawn. Between phases this follows the card's own transport —
    /// a waiting break starts before a fresh focus.
    public func handleReturnNudgeAction() {
        notifier.cancelReturnNudge()
        if pendingNext != nil { startNext(); return }
        guard activePhase == nil else { return }
        start(.focus)
    }
}
