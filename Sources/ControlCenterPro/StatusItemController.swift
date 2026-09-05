// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPUI
import Observation

/// The menu bar item: left click toggles the panel, right click shows
/// the menu. When edit mode is active the Done and Add controls live here
/// rather than inside the panel (ccp-edit-menu-bar).
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
        rebuildMenu()
        trackEditingChanges()

        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.3.group.fill",
                accessibilityDescription: "Control Center Pro"
            )
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseDown])
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        if panel.editor.isEditing {
            let doneItem = NSMenuItem(title: "Done", action: #selector(doneEditing), keyEquivalent: "")
            doneItem.target = self
            doneItem.keyEquivalentModifierMask = []
            menu.addItem(doneItem)
            let addItem = NSMenuItem(title: "Add Widget…", action: #selector(addWidget), keyEquivalent: "")
            addItem.target = self
            menu.addItem(addItem)
            menu.addItem(.separator())
        } else {
            let editItem = NSMenuItem(title: "Edit Widgets", action: #selector(editWidgets), keyEquivalent: "")
            editItem.target = self
            menu.addItem(editItem)
        }
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func finishEditing() {
        if panel.editor.isShowingGallery {
            panel.finishEditingKeepingGallery()
        } else {
            panel.stopEditing()
        }
    }

    private func trackEditingChanges() {
        withObservationTracking {
            _ = panel.editor.isEditing
            _ = panel.editor.isShowingGallery
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trackEditingChanges()
                self.rebuildMenu()
                if let button = self.item.button {
                    let symbol = self.panel.editor.isEditing ? "checkmark.circle.fill" : "rectangle.3.group.fill"
                    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: self.panel.editor.isEditing ? "Done editing" : "Control Center Pro")
                }
            }
        }
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            if panel.editor.isEditing {
                finishEditing()
            } else {
                panel.toggle(from: sender)
            }
            return
        }

        let isRightClick = event.type == .rightMouseDown
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))

        if isRightClick {
            // Ensure the menu reflects the editing state that was just entered
            // via a hold (which sets isEditing synchronously but rebuildMenu
            // is observed asynchronously).
            rebuildMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
        } else {
            if panel.editor.isEditing {
                finishEditing()
            } else {
                panel.toggle(from: sender)
            }
        }
    }

    @objc private func editWidgets() {
        panel.showAndStartEditing(from: item.button)
    }

    @objc private func doneEditing() { finishEditing() }

    @objc private func addWidget() {
        panel.showGallery()
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
