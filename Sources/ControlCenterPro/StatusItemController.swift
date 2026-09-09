// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
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
    private var countdownTimer: Timer?

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
        trackFocusCountdown()
        updateFocusCountdown()

        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "circle.grid.2x2.fill",
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
        let stickyItem = NSMenuItem(title: "New Sticky", action: #selector(newSticky), keyEquivalent: "")
        stickyItem.target = self
        menu.addItem(stickyItem)
        let archived = StickyStore.shared.archived
        if !archived.isEmpty {
            let restoreItem = NSMenuItem(title: "Restore Sticky", action: nil, keyEquivalent: "")
            let restoreMenu = NSMenu()
            for sticky in archived {
                let item = NSMenuItem(
                    title: sticky.displayTitle,
                    action: #selector(restoreSticky(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = sticky.id.uuidString
                restoreMenu.addItem(item)
            }
            restoreItem.submenu = restoreMenu
            menu.addItem(restoreItem)
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
                    let symbol = self.panel.editor.isEditing ? "checkmark.circle.fill" : "circle.grid.2x2.fill"
                    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: self.panel.editor.isEditing ? "Done editing" : "Control Center Pro")
                }
            }
        }
    }

    /// The Focus countdown beside the icon while a stretch runs. The item is
    /// icon-only otherwise — menu-bar space is spent only while it says
    /// something. Monospaced digits keep the variable-length item from
    /// jittering as the seconds turn over.
    ///
    /// The refresh timer lives here, not in the store: the store's ticker
    /// stops with the panel, and a deactivated widget must not keep the app
    /// awake. This timer runs only while a stretch is active — a shut panel
    /// with nothing running still costs nothing.
    private func trackFocusCountdown() {
        withObservationTracking {
            _ = FocusStore.shared.activePhase
            _ = FocusStore.shared.pausedRemaining
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trackFocusCountdown()
                self.updateFocusCountdown()
            }
        }
    }

    private func updateFocusCountdown() {
        let store = FocusStore.shared
        // Drive the store's own tick: with the panel shut its ticker is
        // stopped, and without this a deadline that passes unseen leaves the
        // title wedged at 0:00 — remaining clamps at zero but never nils.
        // Silent with the panel shut (the chime is a panel-open sound); the
        // scheduled notification already announced the ending.
        store.tick()
        guard let remaining = store.remaining(at: Date()) else {
            stopCountdownTimer()
            item.length = NSStatusItem.squareLength
            item.button?.title = ""
            return
        }
        item.length = NSStatusItem.variableLength
        if let button = item.button {
            button.font = NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize, weight: .regular)
            button.title = FocusStore.mmss(remaining)
        }
        // A paused stretch has no deadline coming — draw its frozen title
        // once and stop, rather than waking every second to repaint it.
        if store.isRunning {
            startCountdownTimer()
        } else {
            stopCountdownTimer()
        }
    }

    private func startCountdownTimer() {
        guard countdownTimer == nil else { return }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFocusCountdown()
            }
        }
    }

    private func stopCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
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

    @objc private func newSticky() {
        panel.newSticky()
    }

    @objc private func restoreSticky(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString)
        else { return }
        // A restored note nobody can see is a note nobody wrote — same rule
        // as a new one.
        if !panel.isVisible, let button = item.button {
            panel.show(from: button)
        }
        StickyStore.shared.unarchive(id)
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
