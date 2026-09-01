// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Carbon.HIToolbox
import Observation
import VorssaintEngines

/// One system-wide key combination, registered with Carbon so it arrives even
/// while another app is in front.
///
/// Carbon rather than a `CGEvent` tap: a tap wants Accessibility, and a
/// shortcut that opens the panel should not be gated behind a permission
/// prompt. Upstream registers its own hotkeys the same way, and the dispatcher
/// hands every hotkey to every handler, so the id below is checked before the
/// callback runs — ours must not answer for the shelf's key or upstream's.
@MainActor
@Observable
public final class GlobalHotkey {
    /// Fired on the main actor when the combination is pressed.
    @ObservationIgnored public var onPress: (() -> Void)?

    /// True when the system refused the combination — almost always because
    /// something else already holds it.
    public private(set) var isUnavailable = false

    @ObservationIgnored private var reference: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var registered: KeyCombination?

    /// Distinguishes our hotkey from every other one on the dispatcher.
    /// 'CCPP', and an id no other registrar in this process uses.
    private static let signature: OSType = 0x4343_5050
    private static let identifier: UInt32 = 1

    public init() {}

    deinit {
        // `unregister` is main-actor bound and deinit is not, but the Carbon
        // calls themselves are free-standing C: releasing the key here is
        // safer than leaving it claimed by an object that is gone.
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Claim `shortcut`, releasing whatever was claimed before. Passing nil
    /// means the feature has no shortcut and claims nothing.
    public func use(_ shortcut: KeyCombination?) {
        guard let shortcut, shortcut.isValid else {
            unregister()
            return
        }
        guard registered != shortcut else { return }
        unregister()
        installHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.bridged.carbonKeyCode,
            shortcut.bridged.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: Self.identifier),
            GetEventDispatcherTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            isUnavailable = true
            return
        }
        self.reference = reference
        registered = shortcut
        isUnavailable = false
    }

    /// Give the combination back to the system — what a shortcut recorder
    /// calls so the user can type the shortcut the app already answers to.
    public func unregister() {
        if let reference {
            UnregisterEventHotKey(reference)
            self.reference = nil
        }
        registered = nil
        isUnavailable = false
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, context -> OSStatus in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &pressed
            )
            // Not ours: hand it back so the dispatcher keeps walking the chain.
            // Returning noErr here would swallow another registrar's key.
            guard pressed.signature == GlobalHotkey.signature,
                  pressed.id == GlobalHotkey.identifier
            else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in hotkey.onPress?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
