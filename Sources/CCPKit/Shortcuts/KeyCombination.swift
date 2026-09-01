// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import VorssaintEngines

/// A key and the modifiers held with it — what a shortcut recorder captures
/// and what `GlobalHotkey` claims from the system.
///
/// Spelling a key code for the keyboard actually attached, deciding which
/// combinations the system will take, and writing one down as text are all
/// upstream's, reached through `BridgedShortcut`. This is the shape CCP passes
/// around, so nothing above this layer names an upstream type.
public struct KeyCombination: Equatable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        public init(eventFlags: NSEvent.ModifierFlags) {
            self.init(bridged: BridgedShortcutModifiers(eventFlags: eventFlags))
        }

        /// The caps as they are written on screen — "⌃⌥⌘".
        public var displayString: String { bridged.displayString }

        init(bridged: BridgedShortcutModifiers) {
            var modifiers: Modifiers = []
            if bridged.contains(.control) { modifiers.insert(.control) }
            if bridged.contains(.option) { modifiers.insert(.option) }
            if bridged.contains(.shift) { modifiers.insert(.shift) }
            if bridged.contains(.command) { modifiers.insert(.command) }
            self = modifiers
        }

        var bridged: BridgedShortcutModifiers {
            var modifiers: BridgedShortcutModifiers = []
            if contains(.control) { modifiers.insert(.control) }
            if contains(.option) { modifiers.insert(.option) }
            if contains(.shift) { modifiers.insert(.shift) }
            if contains(.command) { modifiers.insert(.command) }
            return modifiers
        }
    }

    let bridged: BridgedShortcut

    public init(keyCode: Int64, modifiers: Modifiers) {
        bridged = BridgedShortcut(keyCode: keyCode, modifiers: modifiers.bridged)
    }

    /// Reads a combination back from the text `storageValue` produced. Nil
    /// when the text is malformed or names a combination this build won't take.
    public init?(storageValue: String) {
        guard let shortcut = BridgedShortcut(storageValue: storageValue) else { return nil }
        bridged = shortcut
    }

    public var keyCode: Int64 { bridged.keyCode }
    public var modifiers: Modifiers { Modifiers(bridged: bridged.modifiers) }

    /// How the combination is written on screen — "⌃⌥⌘Space".
    public var displayString: String { bridged.displayString }
    public var storageValue: String { bridged.storageValue }

    /// Whether the system will take it: a key it knows, held with a primary
    /// modifier — or a function key, which is safe to claim on its own.
    public var isValid: Bool { bridged.isValid }

    /// Delete pressed alone means "take the shortcut off" while a recorder is
    /// listening, the way every shortcut field on this system behaves.
    public static func clearsShortcut(keyCode: Int64, modifiers: Modifiers) -> Bool {
        BridgedShortcut.clearsShortcut(keyCode: keyCode, modifiers: modifiers.bridged)
    }
}
