// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPUI

/// The menu bar item: left click toggles the panel, right click shows
/// the menu (Edit / Settings / Quit).
@MainActor
final class StatusItemController {
    private let item: NSStatusItem
    private let panel: ControlPanelController
    private let settingsWindow: SettingsWindowController
    private let menu: NSMenu

    /// What the panel anchors itself to. Read by the global shortcut, which
    /// has no click of its own to say which screen the user is on.
    var button: NSStatusBarButton? { item.button }

    init(panel: ControlPanelController, settingsWindow: SettingsWindowController) {
        self.panel = panel
        self.settingsWindow = settingsWindow
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: #selector(editWidgets), keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "square.grid.2x2",
                accessibilityDescription: "Control Center Pro"
            )
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseDown])
        }
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            panel.toggle(from: sender)
            return
        }

        let isRightClick = event.type == .rightMouseDown
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))

        if isRightClick {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
        } else {
            panel.toggle(from: sender)
        }
    }

    @objc private func editWidgets() {
        panel.showAndStartEditing(from: item.button)
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
