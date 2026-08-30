// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit

/// Watches for the two gestures that mean "put the panel away": a click
/// somewhere else, and Esc.
///
/// The panel takes key focus but never activates the app, so it gets no
/// `resignKey` when the user goes back to what they were doing — the events
/// have to be watched for, and watching stops the moment the panel is down.
/// A monitor outliving the panel it dismisses is the whole bug this type
/// exists to not have: `start()` twice in a row installs one set, and `stop()`
/// removes every handle it holds.
@MainActor
final class PanelDismissalMonitor {
    private let monitors: EventMonitors
    private let dismiss: () -> Void
    private var handles: [Any] = []

    init(monitors: EventMonitors = .system, dismiss: @escaping () -> Void) {
        self.monitors = monitors
        self.dismiss = dismiss
    }

    var isWatching: Bool { !handles.isEmpty }

    func start() {
        guard handles.isEmpty else { return }

        // Only clicks in *other* apps dismiss. A local mouse monitor would
        // also see the click on the status item, which already toggles the
        // panel — the panel would close here and reopen there, and the item
        // would look like it had stopped working.
        let outsideClick = monitors.addGlobal([.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.dismiss()
        }

        // Esc arrives locally because the panel is key, which is what keeps
        // this off the accessibility permission a global keyboard monitor
        // would demand. Swallowed rather than passed on: the panel it was
        // meant for is gone by then.
        let escape = monitors.addLocal(.keyDown) { [weak self] event in
            guard event.isEscape else { return event }
            self?.dismiss()
            return nil
        }

        handles = [outsideClick, escape].compactMap { $0 }
    }

    func stop() {
        handles.forEach(monitors.remove)
        handles.removeAll()
    }
}

/// The AppKit event-monitor API, narrowed to the two kinds of watching
/// dismissal does and to the one thing that undoes them.
///
/// It is a seam rather than a direct call because the invariant worth proving —
/// that opening and closing the panel all day leaves no monitor behind — is
/// about the calls made, and `NSEvent` will not say what it is holding.
///
/// Deliberately not main-actor isolated: it holds `NSEvent`'s own functions,
/// which have no isolation, and isolating it would only stop the monitor from
/// naming `.system` as a default.
struct EventMonitors {
    var addGlobal: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any?
    var addLocal: (NSEvent.EventTypeMask, @escaping (NSEvent) -> NSEvent?) -> Any?
    var remove: (Any) -> Void

    static let system = EventMonitors(
        addGlobal: NSEvent.addGlobalMonitorForEvents(matching:handler:),
        addLocal: NSEvent.addLocalMonitorForEvents(matching:handler:),
        remove: NSEvent.removeMonitor
    )
}

private extension NSEvent {
    /// Virtual keycode for Esc, which is the same key whatever the keyboard
    /// layout maps it to — `characters` is not.
    private static let escapeKeyCode: UInt16 = 53

    var isEscape: Bool { keyCode == Self.escapeKeyCode }
}
