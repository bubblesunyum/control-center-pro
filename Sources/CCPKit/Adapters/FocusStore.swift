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
    @ObservationIgnored private let file: JSONFileStore<FocusPersisted>
    @ObservationIgnored private var openSessionID: UUID?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var panelOpenCount = 0

    /// Sessions older than this fall off the log on save — history, not archive.
    static let sessionRetention: TimeInterval = 90 * 24 * 60 * 60
    static let sessionCap = 2000

    public convenience init() {
        self.init(in: .applicationSupport, notifier: LiveFocusNotifier())
    }

    init(
        in directory: URL,
        clock: FocusClock = SystemFocusClock(),
        // Noop by default on purpose: UNUserNotificationCenter.current() has
        // no bundle under xctest and traps, so only the shipped shared
        // instance opts into the live notifier. Tests hand a fake.
        notifier: FocusNotifier = NoopFocusNotifier()
    ) {
        self.clock = clock
        self.notifier = notifier
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
        self.notificationStatus = .unknown
        Task { await refreshNotificationStatus() }
        // A deadline that passed while quit already fired its notification —
        // land in the finished state silently rather than chiming at launch.
        reconcile(announce: false)
        ensureTicker()
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
        maybeRequestAuthorization()
        save()
        ensureTicker()
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
        ensureTicker()
    }

    public func resume() {
        guard activePhase != nil, let paused = pausedRemaining else { return }
        now = clock.now()
        let deadline = now.addingTimeInterval(paused)
        endsAt = deadline
        pausedRemaining = nil
        scheduleNotification(for: activePhase!, endingAt: deadline)
        save()
        ensureTicker()
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
        save()
        ensureTicker()
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
        save()
        ensureTicker()
    }

    public func updateSettings(_ next: FocusSettings) {
        settings = next.clamped
        // A pendingNext decided under the old switch goes stale: turning
        // breaks off while waiting on a break must not still offer it.
        if activePhase == nil, !settings.breaksEnabled, pendingNext == .shortBreak {
            pendingNext = .focus
        }
        save()
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
        ensureTicker()
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
            openSessionID: openSessionID
        ))
    }
}
