// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import SwiftUI

/// Where a drag gesture opened, in the controller's own vocabulary. The cases
/// are `ShelfDropTrigger`'s; the alias keeps callers (and tests) from
/// reaching past CCPUI for them.
public typealias DropOverlayOrigin = ShelfDropTrigger.Origin

/// The drop-catcher: while the user drags something the shelf can keep, a
/// little pill hangs below the menu-bar item as a drop target. One accept per
/// gesture — it ticks green and hides, and never re-shows until the next
/// drag. The decision half of upstream's docked pill (`ShelfService`
/// detection, positioning, watchdog, delayed hide); the shake / edge / hotkey
/// triggers and the stick-around mini-shelf were deliberately left behind.
///
/// Detection policy lives in `ShelfDropTrigger` (CCPKit, unit-tested) — CCPUI
/// never touches an upstream type. This owns the AppKit mechanics: the global
/// mouse monitor, the button-state watchdog, and the panel.
@MainActor
@Observable
public final class DropOverlayController {
    private let monitors: EventMonitors
    private let makePanel: (DropOverlayRoot) -> any DropOverlayPanel
    private let statusFrame: () -> NSRect?
    private let isSuppressed: () -> Bool
    private let dragChangeCount: () -> Int
    private let hasDroppableContent: () -> Bool
    private let isLeftButtonDown: () -> Bool
    private let gestureOrigin: (NSEvent) -> DropOverlayOrigin
    private let tickDelay: TimeInterval
    private let endDelay: TimeInterval

    private var monitorHandle: Any?
    private var trigger = ShelfDropTrigger()
    private var watchdog: Timer?
    private var endWork: DispatchWorkItem?
    private var tickWork: DispatchWorkItem?
    private var panel: (any DropOverlayPanel)?

    /// The pill is currently offered as a target.
    public private(set) var isShowing = false
    /// A drop just landed; the pill shows its tick until the hide fires.
    public private(set) var justCaught = false
    private var dragActive = false
    private var acceptedInGesture = false

    /// App entry point. The closures keep this free of status-item and panel
    /// knowledge: AppDelegate is still the only place that has all four.
    public convenience init(
        statusFrame: @escaping () -> NSRect?,
        isSuppressed: @escaping () -> Bool
    ) {
        self.init(
            monitors: .system,
            makePanel: { _ in AppKitDropOverlayPanel() },
            statusFrame: statusFrame,
            isSuppressed: isSuppressed,
            dragChangeCount: { NSPasteboard(name: .drag).changeCount },
            hasDroppableContent: { ShelfStore.shared.canAcceptPasteboard(NSPasteboard(name: .drag)) },
            isLeftButtonDown: { CGEventSource.buttonState(.combinedSessionState, button: .left) },
            tickDelay: 0.9,
            endDelay: 0.15
        )
        start()
    }

    /// Test seam: every boundary stubbed — monitors, panel, pasteboard reads,
    /// button state, delays — so the state machine is provable without a real
    /// drag. Same shape as `PanelDismissalMonitor(monitors:dismiss:)`.
    init(
        monitors: EventMonitors,
        makePanel: @escaping (DropOverlayRoot) -> any DropOverlayPanel,
        statusFrame: @escaping () -> NSRect?,
        isSuppressed: @escaping () -> Bool,
        dragChangeCount: @escaping () -> Int,
        hasDroppableContent: @escaping () -> Bool,
        isLeftButtonDown: @escaping () -> Bool,
        gestureOrigin: @escaping (NSEvent) -> DropOverlayOrigin = ShelfDropTrigger.gestureOrigin,
        tickDelay: TimeInterval,
        endDelay: TimeInterval
    ) {
        self.monitors = monitors
        self.makePanel = makePanel
        self.statusFrame = statusFrame
        self.isSuppressed = isSuppressed
        self.dragChangeCount = dragChangeCount
        self.hasDroppableContent = hasDroppableContent
        self.isLeftButtonDown = isLeftButtonDown
        self.gestureOrigin = gestureOrigin
        self.tickDelay = tickDelay
        self.endDelay = endDelay
    }

    /// A monitor left installed is an overlay that appears for reasons nobody
    /// can see anymore: `start` twice installs one set, `stop` removes it.
    public func start() {
        guard monitorHandle == nil else { return }
        monitorHandle = monitors.addGlobal([.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
            [weak self] event in
            Task { @MainActor [weak self] in self?.handleMonitorEvent(event) }
        }
    }

    public func stop() {
        if let handle = monitorHandle { monitors.remove(handle) }
        monitorHandle = nil
        watchdog?.invalidate()
        watchdog = nil
        endWork?.cancel()
        endWork = nil
        tickWork?.cancel()
        tickWork = nil
        // Leave nothing behind: no orphaned pill, no stale gesture for the
        // next start to inherit.
        trigger.endGesture(dragChangeCount: dragChangeCount())
        dragActive = false
        acceptedInGesture = false
        justCaught = false
        setShowing(false)
    }

    // MARK: - Monitor

    /// Internal so tests can drive the real handler synchronously; production
    /// reaches it through the monitor, which hops threads via `Task`.
    func handleMonitorEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            beginGesture(with: event)
        case .leftMouseUp:
            endGesture()
        case .leftMouseDragged:
            // The window server sometimes eats the mouse-down (window moves),
            // so the first dragged event opens the gesture instead.
            if !trigger.isGestureOpen { beginGesture(with: event) }
            noteDragMoved()
        default:
            break
        }
    }

    private func beginGesture(with event: NSEvent) {
        // A mouse-down means any pending end or tick was stale: the old drag
        // is over and a new gesture starts, so a previous drop's hide must
        // not fire into this drag.
        endWork?.cancel()
        endWork = nil
        tickWork?.cancel()
        tickWork = nil
        let origin = gestureOrigin(event)
        trigger.beginGesture(
            dragChangeCount: dragChangeCount(),
            beganInDock: origin == .dock,
            beganInOwnApp: origin == .ownApp
        )
        acceptedInGesture = false
        justCaught = false
        setShowing(false)
        startWatchdog()
    }

    private func noteDragMoved() {
        // Drag events still flowing means the drag is alive: a pending end
        // queued by a mouse-up that turned out to start a new drag is stale.
        endWork?.cancel()
        endWork = nil
        let active = trigger.isContentDrag(dragChangeCount: dragChangeCount()) {
            hasDroppableContent()
        }
        dragActive = active
        if active, !acceptedInGesture, !isSuppressed() {
            setShowing(true)
        } else {
            setShowing(false)
        }
    }

    private func endGesture() {
        trigger.endGesture(dragChangeCount: dragChangeCount())
        watchdog?.invalidate()
        watchdog = nil
        // The short delay lets a drop still landing on the pill claim it
        // first; a single cancellable item so the monitor and the watchdog
        // can't race each other.
        guard dragActive, endWork == nil else {
            dragActive = false
            return
        }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.endWorkFired() }
        }
        endWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + endDelay, execute: work)
    }

    /// The drag ended. A drop keeps the tick pill; a miss just goes away.
    func endWorkFired() {
        endWork = nil
        dragActive = false
        if !justCaught { setShowing(false) }
    }

    /// Ends the gesture even when no mouse-up ever reaches the monitor: the
    /// drag machinery can consume it, the drop may land on one of our own
    /// windows, or the drag may be cancelled. The physical button is the one
    /// truth that survives all of those.
    func watchdogFired() {
        guard trigger.isGestureOpen || dragActive else {
            watchdog?.invalidate()
            watchdog = nil
            return
        }
        // Sampled here as well as on dragged events: the panel can open
        // mid-drag under a stationary mouse (hotkey), and no dragged event
        // would ever re-read the suppression.
        if isSuppressed() {
            setShowing(false)
        } else if !isLeftButtonDown() {
            endGesture()
        }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.watchdogFired() }
        }
        watchdog?.tolerance = 0.05
    }

    // MARK: - Acceptance

    /// The pill's drop landed in the store. Tick, then always hide — even
    /// with the button still down, further dragged events must not re-show
    /// until the next gesture. No stick-around, by design.
    func didAcceptDrop() {
        endWork?.cancel()
        endWork = nil
        tickWork?.cancel()
        acceptedInGesture = true
        justCaught = true
        if !isSuppressed() { setShowing(true) }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.tickWorkFired() }
        }
        tickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + tickDelay, execute: work)
    }

    func tickWorkFired() {
        tickWork = nil
        justCaught = false
        setShowing(false)
    }

    // MARK: - Panel

    private func setShowing(_ show: Bool) {
        if show {
            guard !isShowing else { return }
            isShowing = true
            ensurePanel().show(anchoredTo: statusFrame(), content: DropOverlayRoot(controller: self))
        } else {
            guard isShowing else { return }
            isShowing = false
            panel?.hide()
        }
    }

    private func ensurePanel() -> any DropOverlayPanel {
        if let panel { return panel }
        let made = makePanel(DropOverlayRoot(controller: self))
        panel = made
        return made
    }
}
