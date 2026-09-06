// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CoreGraphics
import VorssaintEngines

/// Whether the pointer gesture in flight is dragging something the shelf can
/// keep, for the drop-catcher overlay. The decision half of upstream's drag
/// monitor (`ShelfService.startDragMonitor` / `isContentDragActive`), minus
/// the shake / edge / hotkey triggers it also served: this answers one
/// question and owns no monitors, windows, or timers.
///
/// Values in, Bool out: the controller reads `NSPasteboard(name: .drag)` and
/// the opening `NSEvent`, this holds the baseline. That keeps the AppKit
/// mechanics injectable and every branch unit-testable.
public struct ShelfDropTrigger: Sendable {
    private var baselineChangeCount = 0
    private var beganInDock = false
    private var beganInOwnApp = false
    private var gestureOpen = false

    public init() {}

    /// The drag pasteboard keeps the last drag's contents indefinitely, so a
    /// retained count alone proves nothing: the baseline is whatever the
    /// count was when this gesture opened, and only a bump past it is fresh
    /// content. Upstream re-baselines on every mouse-down for the same reason.
    public mutating func beginGesture(dragChangeCount: Int, beganInDock: Bool, beganInOwnApp: Bool) {
        baselineChangeCount = dragChangeCount
        self.beganInDock = beganInDock
        self.beganInOwnApp = beganInOwnApp
        gestureOpen = true
    }

    /// Absorb whatever a finished drag left retained, so a later gesture
    /// whose start nobody saw cannot mistake it for fresh content.
    public mutating func endGesture(dragChangeCount: Int) {
        baselineChangeCount = dragChangeCount
        beganInDock = false
        beganInOwnApp = false
        gestureOpen = false
    }

    public var isGestureOpen: Bool { gestureOpen }

    /// True once the drag pasteboard moves past the gesture's baseline — or
    /// the gesture began in the Dock, which publishes before the mouse-down —
    /// holding something the shelf accepts. Never true for a gesture that
    /// started in one of our own windows, which is a drag *out of* the shelf.
    /// `hasDroppableContent` runs last: most dragged events fail the cheap
    /// integer check first.
    public func isContentDrag(dragChangeCount: Int, hasDroppableContent: () -> Bool) -> Bool {
        guard gestureOpen, !beganInOwnApp else { return false }
        return BridgedShelfInteraction.isContentDrag(
            baselineChangeCount: baselineChangeCount,
            changeCount: dragChangeCount,
            beganInDock: beganInDock,
            hasDroppableContent: hasDroppableContent
        )
    }

    /// Where the opening event came from. A straight port of
    /// `ShelfService.eventBelongsToDock`, plus our own pid: a drag out of the
    /// shelf starts with a mouse-down in one of our panels, and without the
    /// own-app check our own freshly published content would read as a
    /// qualifying drag. (When the window server eats the mouse-down and the
    /// gesture opens late, the baseline already absorbed our content instead —
    /// same trap, second net.)
    public static func gestureOrigin(_ event: NSEvent) -> Origin {
        if let cgEvent = event.cgEvent {
            let pid = pid_t(cgEvent.getIntegerValueField(.eventSourceUnixProcessID))
            if let origin = classify(pid: pid) { return origin }
        }
        if event.windowNumber > 0,
           let infos = CGWindowListCopyWindowInfo(
               .optionIncludingWindow,
               CGWindowID(event.windowNumber)
           ) as? [[String: Any]],
           let owner = infos.first
        {
            if let pidNumber = owner[kCGWindowOwnerPID as String] as? NSNumber,
               let origin = classify(pid: pid_t(pidNumber.int32Value))
            {
                return origin
            }
            if (owner[kCGWindowOwnerName as String] as? String) == "Dock" { return .dock }
        }
        return .elsewhere
    }

    public enum Origin: Sendable, Equatable {
        case dock, ownApp, elsewhere
    }

    private static func classify(pid: pid_t) -> Origin? {
        if pid == getpid() { return .ownApp }
        if isDockProcess(pid) { return .dock }
        return nil
    }

    private static func isDockProcess(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock"
    }
}
