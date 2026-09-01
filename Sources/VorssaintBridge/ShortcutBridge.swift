// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import Foundation

/// The modifiers a shortcut may carry, restated from upstream's
/// `GlobalShortcutModifiers`.
public struct BridgedShortcutModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let control = BridgedShortcutModifiers(rawValue: 1 << 0)
    public static let option = BridgedShortcutModifiers(rawValue: 1 << 1)
    public static let shift = BridgedShortcutModifiers(rawValue: 1 << 2)
    public static let command = BridgedShortcutModifiers(rawValue: 1 << 3)

    public init(eventFlags: NSEvent.ModifierFlags) {
        self.init(GlobalShortcutModifiers(eventFlags: eventFlags))
    }

    init(_ upstream: GlobalShortcutModifiers) {
        var modifiers: BridgedShortcutModifiers = []
        if upstream.contains(.control) { modifiers.insert(.control) }
        if upstream.contains(.option) { modifiers.insert(.option) }
        if upstream.contains(.shift) { modifiers.insert(.shift) }
        if upstream.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }

    /// The caps as they are written on screen — "⌃⌥⌘".
    public var displayString: String { upstream.keyCaps.joined() }

    var upstream: GlobalShortcutModifiers {
        var modifiers: GlobalShortcutModifiers = []
        if contains(.control) { modifiers.insert(.control) }
        if contains(.option) { modifiers.insert(.option) }
        if contains(.shift) { modifiers.insert(.shift) }
        if contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}

/// A key combination the system can be asked to deliver from anywhere.
///
/// Upstream's `GlobalShortcut` already knows how to spell a key code for the
/// current keyboard layout, which combinations are worth registering, and how
/// to store one as text — all of it hard-won and none of it worth writing a
/// second time. This restates it as a public value CCP can hold.
public struct BridgedShortcut: Equatable, Hashable, Sendable {
    private let upstream: GlobalShortcut

    public init(keyCode: Int64, modifiers: BridgedShortcutModifiers) {
        upstream = GlobalShortcut(keyCode: keyCode, modifiers: modifiers.upstream)
    }

    /// Reads a shortcut back from the text `storageValue` produced. Nil when
    /// the text is malformed or names a combination that isn't usable.
    public init?(storageValue: String) {
        guard let shortcut = GlobalShortcut(storageValue: storageValue) else { return nil }
        upstream = shortcut
    }

    public var keyCode: Int64 { upstream.keyCode }
    public var modifiers: BridgedShortcutModifiers { BridgedShortcutModifiers(upstream.modifiers) }

    /// How the combination is written on screen — "⌃⌥⌘Space".
    public var displayString: String { upstream.displayString }
    public var storageValue: String { upstream.storageValue }

    /// Whether the system will take this: a known key, and either a primary
    /// modifier or a function key, which is safe to claim on its own.
    public var isValid: Bool { upstream.isValid }

    public var carbonKeyCode: UInt32 { upstream.carbonKeyCode }
    public var carbonModifiers: UInt32 { upstream.carbonModifiers }

    /// Delete pressed alone means "take the shortcut off" while a recorder is
    /// listening, the way every shortcut field on this system behaves.
    public static func clearsShortcut(keyCode: Int64, modifiers: BridgedShortcutModifiers) -> Bool {
        GlobalShortcut.clearsShortcut(keyCode: keyCode, modifiers: modifiers.upstream)
    }
}

/// Upstream's recording tap: while a shortcut field is listening, it takes key
/// events ahead of the system so a combination the system itself answers to —
/// ⌘` cycling windows, ⌘Space opening search — lands in the field instead of
/// doing its usual job.
///
/// Needs Accessibility. `begin` returns false without it, and the caller falls
/// back to the ordinary event path, which is what the field always had.
public enum BridgedKeyRecordingTap {
    @discardableResult
    @MainActor
    public static func begin(
        _ handler: @escaping (Int64, BridgedShortcutModifiers) -> Void
    ) -> Bool {
        ShortcutRecordingTap.begin { keyCode, modifiers in
            handler(keyCode, BridgedShortcutModifiers(modifiers))
        }
    }

    @MainActor
    public static func end() {
        ShortcutRecordingTap.end()
    }
}
