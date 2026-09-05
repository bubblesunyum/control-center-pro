// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import SwiftUI

/// The Settings window: an ordinary titled window, built on first use and kept
/// afterwards so reopening it lands where the user left it.
///
/// The app is an accessory and has no windows of its own, so opening this one
/// also has to activate the app — without that the window comes up behind
/// whatever is in front and never takes the keyboard, which a shortcut
/// recorder cannot work without.
@MainActor
public final class SettingsWindowController {
    private let settings: SettingsStore
    private let craft: CraftConnectionModel
    private let hotkey: GlobalHotkey
    private var window: NSWindow?

    public init(settings: SettingsStore, craft: CraftConnectionModel, hotkey: GlobalHotkey) {
        self.settings = settings
        self.craft = craft
        self.hotkey = hotkey
    }

    public func show() {
        let isFirstShow = window == nil
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // After it is on screen, not before: the hosting controller sizes the
        // window when it appears, and centring a window that is still empty
        // puts its corner in the middle of the display rather than the window.
        if isFirstShow { window.center() }
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: SettingsView(settings: settings, craft: craft, hotkey: hotkey))
        host.sizingOptions = .preferredContentSize

        let window = NSWindow(contentViewController: host)
        window.title = "Control Center Pro Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        return window
    }
}
