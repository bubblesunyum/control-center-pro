// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import Carbon.HIToolbox
import SwiftUI

/// A field that listens for a key combination and reports the one it heard —
/// the control every app with a global shortcut has.
///
/// Click it and it takes the keyboard: while it listens, every key is swallowed
/// so typing a combination something already answers to lands here instead of
/// firing it. The combination is taken when the last key is lifted rather than
/// the moment one goes down, so ⌘ then ` is recorded as ⌘` — a field that
/// committed on the first key down could only ever record single keys.
///
/// Escape backs out, Delete on its own clears, and a combination the system
/// won't register — a bare letter — is not taken; the field keeps listening.
public struct ShortcutRecorder: View {
    /// What the field is doing, for a caption that has to explain it.
    public struct Status: Equatable, Sendable {
        public var isRecording = false
        /// False while recording without the Accessibility permission the tap
        /// needs, which is when the combinations the system keeps for itself
        /// cannot be recorded.
        public var readsSystemShortcuts = true
    }

    @Binding private var shortcut: KeyCombination?
    private let onStatusChanged: (Status) -> Void

    @State private var capture = KeyCapture()
    @State private var isRecording = false
    /// Heard, and waiting for the keys to come up before it is taken.
    @State private var pending: KeyCombination?
    @State private var heldModifiers: KeyCombination.Modifiers = []

    /// - Parameter onStatusChanged: told when the field takes and gives back
    ///   the keyboard, so the owner can release the shortcuts it holds for as
    ///   long as the user is typing a new one.
    public init(
        shortcut: Binding<KeyCombination?>,
        onStatusChanged: @escaping (Status) -> Void = { _ in }
    ) {
        _shortcut = shortcut
        self.onStatusChanged = onStatusChanged
    }

    public var body: some View {
        Button(action: startRecording) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .frame(width: Layout.shortcutFieldWidth)
        .accessibilityLabel("Keyboard shortcut")
        .accessibilityValue(shortcut?.displayString ?? "None")
        .onDisappear(perform: stopRecording)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            // The window going behind takes the keyboard with it, and a field
            // still believing it is listening would swallow the next keys.
            stopRecording()
        }
    }

    private var title: String {
        guard isRecording else { return shortcut?.displayString ?? "Record Shortcut" }
        if let pending { return pending.displayString }
        return heldModifiers.isEmpty ? "Type a shortcut" : heldModifiers.displayString
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        pending = nil
        heldModifiers = []
        capture.start(handle)
        onStatusChanged(Status(isRecording: true,
                               readsSystemShortcuts: capture.readsSystemShortcuts))
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        pending = nil
        heldModifiers = []
        capture.stop()
        onStatusChanged(Status())
    }

    private func take(_ combination: KeyCombination?) {
        shortcut = combination
        stopRecording()
    }

    private func handle(_ event: KeyCapture.Event) {
        switch event {
        case let .pressed(keyCode, modifiers):
            heldModifiers = modifiers
            if keyCode == Int64(kVK_Escape), modifiers.isEmpty {
                stopRecording()
                return
            }
            if KeyCombination.clearsShortcut(keyCode: keyCode, modifiers: modifiers) {
                take(nil)
                return
            }
            let candidate = KeyCombination(keyCode: keyCode, modifiers: modifiers)
            guard candidate.isValid else { return }
            pending = candidate
            // A function key stands alone, so there is nothing left to lift.
            if modifiers.isEmpty { take(candidate) }

        case let .modifiersChanged(modifiers):
            heldModifiers = modifiers
            // Every key back up: the combination the user meant is complete.
            if modifiers.isEmpty, let pending { take(pending) }
        }
    }
}
