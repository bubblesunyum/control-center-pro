// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPUI

/// The menu bar item: left click toggles the panel, right click shows
/// the menu (Edit / Quit).
@MainActor
final class StatusItemController {
    private let item: NSStatusItem
    private let panel: ControlPanelController
    private let menu: NSMenu

    init(panel: ControlPanelController) {
        self.panel = panel
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: #selector(editWidgets), keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)
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

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
