// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit

/// Every key press and every change of the modifiers held, for as long as a
/// shortcut recorder is listening.
///
/// Two sources, because no single one sees everything. Presses come from
/// `KeyRecordingTap`, which sits ahead of the system and is the only way a
/// combination the system has claimed — ⌘` cycling windows, ⌘Space opening
/// search — is ever seen by an app at all; without Accessibility that tap
/// cannot exist and ordinary key events stand in, which records everything
/// except those system combinations. Modifiers always come from an ordinary
/// local monitor: the tap takes key events only, so a modifier going down or
/// coming back up still arrives the usual way.
@MainActor
final class KeyCapture {
    enum Event {
        case pressed(keyCode: Int64, modifiers: KeyCombination.Modifiers)
        case modifiersChanged(KeyCombination.Modifiers)
    }

    /// False when the tap could not be built, meaning the combinations the
    /// system keeps for itself will not reach the recorder.
    private(set) var readsSystemShortcuts = false

    private var monitor: Any?
    /// Read from `deinit`, which is not on the main actor.
    nonisolated(unsafe) private var isCapturing = false

    deinit {
        // The view can go away mid-recording — a window closing, a sheet
        // dismissed. The tap swallows keys for every app on the system, so
        // leaving one installed behind a vanished field would kill the
        // keyboard everywhere. Give it back even from here.
        guard isCapturing else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { KeyRecordingTap.end() } }
    }

    func start(_ onEvent: @escaping (Event) -> Void) {
        guard monitor == nil else { return }

        isCapturing = true
        readsSystemShortcuts = KeyRecordingTap.begin { keyCode, modifiers in
            onEvent(.pressed(keyCode: keyCode, modifiers: modifiers))
        }

        var mask: NSEvent.EventTypeMask = .flagsChanged
        if !readsSystemShortcuts { mask.insert(.keyDown) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            let modifiers = KeyCombination.Modifiers(eventFlags: event.modifierFlags)
            guard event.type == .keyDown else {
                onEvent(.modifiersChanged(modifiers))
                return event
            }
            onEvent(.pressed(keyCode: Int64(event.keyCode), modifiers: modifiers))
            // Swallowed: an unhandled key would beep, and a handled one would
            // reach whatever is behind the field.
            return nil
        }
    }

    /// Gives the keyboard back. Safe to call when nothing was started.
    func stop() {
        isCapturing = false
        KeyRecordingTap.end()
        readsSystemShortcuts = false
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
