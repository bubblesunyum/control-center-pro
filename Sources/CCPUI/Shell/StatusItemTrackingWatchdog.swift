// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit

/// Rescues the menu-bar item when a leftMouseUp is lost mid-click.
///
/// A click on the status button runs inside AppKit's mouse-tracking loop on
/// the main thread; if the matching mouse-up never arrives the thread waits
/// there forever and the app is frozen. A local event monitor cannot see the
/// missing release — events consumed by a tracking loop never reach monitors
/// — so while armed this polls instead: a timer on the main run loop's common
/// modes (which fires inside tracking too) counts consecutive ticks with the
/// button physically up, and after three of them posts one synthetic
/// leftMouseUp far off-screen — outside the button, so no action fires — and
/// stands down. A tracking loop that ended on its own reads back a normal
/// run-loop mode on the next tick, which disarms with nothing posted.
@MainActor
public final class StatusItemTrackingWatchdog {
    private static let tickInterval: TimeInterval = 0.1
    private static let requiredUpTicks = 3

    private let seam: StatusItemTrackingSeam
    private let hasMenu: () -> Bool
    private let isStatusEvent: (NSEvent) -> Bool
    private var monitorHandle: Any?
    private var timerHandle: Any?
    private var upTicks = 0

    /// Production entry point: the menu check and the status-window match read
    /// the live item; every AppKit call underneath goes through the seam.
    public convenience init(statusItem: NSStatusItem) {
        self.init(
            seam: .system,
            hasMenu: { [weak statusItem] in statusItem?.menu != nil },
            isStatusEvent: { [weak statusItem] event in
                guard let window = statusItem?.button?.window else { return false }
                return event.window === window
            }
        )
    }

    init(
        seam: StatusItemTrackingSeam,
        hasMenu: @escaping () -> Bool,
        isStatusEvent: @escaping (NSEvent) -> Bool
    ) {
        self.seam = seam
        self.hasMenu = hasMenu
        self.isStatusEvent = isStatusEvent
    }

    var isArmed: Bool { timerHandle != nil }

    /// Installs the mouse-down watch. Starting twice installs one monitor.
    public func start() {
        guard monitorHandle == nil else { return }
        monitorHandle = seam.addMonitor(.leftMouseDown) { [weak self] event in
            guard let self else { return event }
            return handleMouseDown(event)
        }
    }

    /// Removes the monitor and stands down the timer, if armed.
    public func stop() {
        disarm()
        if let handle = monitorHandle { seam.removeMonitor(handle) }
        monitorHandle = nil
    }

    private func handleMouseDown(_ event: NSEvent) -> NSEvent? {
        // A menu assigned to the item means AppKit owns the coming tracking
        // itself (the right-click path drops a menu and synthetically clicks
        // it); there is no button loop here to rescue.
        guard !hasMenu() else { return event }
        guard isStatusEvent(event) else { return event }
        arm()
        return event
    }

    private func arm() {
        guard timerHandle == nil else { return }
        upTicks = 0
        timerHandle = seam.scheduleTimer(Self.tickInterval) { [weak self] in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    /// One poll, driven by the timer in production and directly in tests: a
    /// tracking loop that ended on its own reads back a normal mode and stands
    /// down with nothing posted; three consecutive ticks with the button
    /// physically up mean the release was lost, so post one synthetic
    /// mouse-up and stand down. A held button resets the count.
    func tick() {
        guard timerHandle != nil else { return }
        guard seam.currentRunLoopMode() == .eventTracking else {
            disarm()
            return
        }
        if seam.pressedMouseButtons() & 1 == 0 {
            upTicks += 1
            if upTicks >= Self.requiredUpTicks {
                seam.postMouseUp()
                disarm()
            }
        } else {
            upTicks = 0
        }
    }

    private func disarm() {
        if let handle = timerHandle { seam.invalidateTimer(handle) }
        timerHandle = nil
        upTicks = 0
    }
}

/// The AppKit boundary this watchdog stands on, narrowed to the calls it
/// makes: watching, polling, and posting the rescue.
///
/// It is a seam rather than direct calls for the same reason `EventMonitors`
/// exists — the invariant worth proving (one synthetic mouse-up exactly when
/// the release was lost, and no monitor or timer left behind) is about the
/// calls made, and the real loop cannot be staged in a test.
///
/// Deliberately not main-actor isolated: it holds `NSEvent`'s own functions,
/// which have no isolation, and isolating it would only stop the production
/// entry point from naming `.system` as a default.
struct StatusItemTrackingSeam {
    var addMonitor: (NSEvent.EventTypeMask, @escaping (NSEvent) -> NSEvent?) -> Any?
    var removeMonitor: (Any) -> Void
    var scheduleTimer: (TimeInterval, @escaping () -> Void) -> Any
    var invalidateTimer: (Any) -> Void
    var pressedMouseButtons: () -> Int
    var currentRunLoopMode: () -> RunLoop.Mode?
    var postMouseUp: () -> Void

    static let system = StatusItemTrackingSeam(
        addMonitor: NSEvent.addLocalMonitorForEvents(matching:handler:),
        removeMonitor: NSEvent.removeMonitor,
        scheduleTimer: { interval, tick in
            // .common, not .default: the timer must fire inside the button's
            // tracking loop, which runs the loop in event-tracking mode.
            let timer = Timer(timeInterval: interval, repeats: true) { _ in tick() }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            return timer
        },
        invalidateTimer: { ($0 as? Timer)?.invalidate() },
        pressedMouseButtons: { NSEvent.pressedMouseButtons },
        currentRunLoopMode: { RunLoop.main.currentMode },
        postMouseUp: {
            // Far off-screen: the stuck tracking loop only needs the release
            // to return, and anywhere near the button would land as a click
            // on it. Posted to our own pid because that is the rescue proven
            // against a live wedge (ccp-b3c5).
            CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: CGPoint(x: -10_000, y: -10_000),
                mouseButton: .left
            )?.postToPid(ProcessInfo.processInfo.processIdentifier)
        }
    )
}
