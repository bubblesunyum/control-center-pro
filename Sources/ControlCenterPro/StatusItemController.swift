// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import CCPUI
import Observation

/// The menu bar item: left click toggles the panel, right click shows
/// the menu. In edit mode the item itself becomes a pill — Add on the left,
/// the checkmark on the right — rather than an icon (ccp-xvth).
///
/// Right-click is the platform's own menu tracking, not ours: the menu is
/// assigned to the item and dropped with a synthetic click, so AppKit owns
/// the tracking and highlight for its duration. The right-vs-left decision
/// reads only the event — what each side then does may touch the panel, but
/// the menu never toggles it and the toggle never shows it (ccp-lusi).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let panel: ControlPanelController
    private let settingsWindow: SettingsWindowController
    private let menu: NSMenu
    private var countdownTimer: Timer?
    private var editPill: EditPill?

    /// What the panel anchors itself to. Read by the global shortcut, which
    /// has no click of its own to say which screen the user is on.
    var button: NSStatusBarButton? { item.button }

    init(panel: ControlPanelController, settingsWindow: SettingsWindowController) {
        self.panel = panel
        self.settingsWindow = settingsWindow
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // A stable name so the system tracks this item across launches —
        // position, and whether it is shown at all. Nameless items sink into
        // the hidden overflow with no address to bring them back by.
        item.autosaveName = "ControlCenterPro"
        menu = NSMenu()
        super.init()
        menu.delegate = self
        rebuildMenu()
        trackEditingChanges()
        trackFocusCountdown()
        trackPanelVisibility()
        updateFocusCountdown()
        syncHighlight()

        if let button = item.button {
            showPlainIcon(on: button)
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            // Up on both sides, the way upstream listens
            // (Vorssaint/App/StatusItemController): a menu shown modally from
            // inside Down-phase tracking wedged the tracking, so the press
            // behind it arrived as a mouse-up and misread as a left click
            // (ccp-nbg3). Up-phase dispatch never runs inside tracking.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// The rest-state icon. Edit mode never sets an image — the pill carries
    /// its own checkmark — so this is both the launch icon and the restore.
    private func showPlainIcon(on button: NSStatusBarButton) {
        button.image = NSImage(
            systemSymbolName: "circle.grid.2x2.fill",
            accessibilityDescription: "Control Center Pro"
        )
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

    /// The edit-mode pill: in edit mode the item stops being an icon and
    /// becomes Add beside the checkmark. Out of edit mode the pill comes out
    /// and the plain icon plus countdown own the item again.
    private func updateEditPill() {
        guard let button = item.button else { return }
        if panel.editor.isEditing {
            button.image = nil
            button.title = ""
            guard editPill == nil else { return }
            let pill = EditPill(
                onDone: { [weak self] in
                    guard let self else { return }
                    self.finishEditing()
                },
                onAdd: { [weak self] in
                    guard let self else { return }
                    self.panel.showGallery()
                },
                onRightClick: { [weak self] in self?.presentMenu() }
            )
            pill.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(pill)
            let ideal = pill.fittingSize
            NSLayoutConstraint.activate([
                pill.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                pill.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                pill.widthAnchor.constraint(equalToConstant: ideal.width),
                pill.heightAnchor.constraint(equalToConstant: ideal.height),
            ])
            // Length from the laid-out width, not the pre-layout estimate: if
            // the solve ever grows past fittingSize the item grows with it
            // instead of clipping the pill (ccp-tk62).
            pill.layoutSubtreeIfNeeded()
            item.length = ceil(pill.bounds.width)
            editPill = pill
        } else {
            editPill?.removeFromSuperview()
            editPill = nil
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
                self.updateEditPill()
                // The plain icon only when the pill is out: in edit mode the
                // pill carries its own checkmark and the image must stay nil.
                if !self.panel.editor.isEditing, let button = self.item.button {
                    self.showPlainIcon(on: button)
                }
                // Restores the item's chrome after the pill comes out; a no-op
                // for it while editing, where the pill owns length and title.
                self.updateFocusCountdown()
            }
        }
    }

    /// The Focus countdown beside the icon while a stretch runs. The item is
    /// icon-only otherwise — menu-bar space is spent only while it says
    /// something. Monospaced digits keep the variable-length item from
    /// jittering as the seconds turn over.
    /// The refresh timer lives here, not in the store: the store's ticker
    /// stops with the panel, and a deactivated widget must not keep the app
    /// awake. This timer runs only while a stretch is active — a shut panel
    /// with nothing running still costs nothing.
    /// Points the countdown text drops to sit centred on the icon.
    private static let countdownBaselineNudge: CGFloat = -1

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

    /// The menu-bar highlight stays on while the panel is up, the way a
    /// menu-backed status item holds it while its menu tracks (ccp-9nte).
    /// One public call each way, driven by visibility so every opener —
    /// click, hotkey, sticky restore — reports the same state. Right-click
    /// menus never touch visibility and keep their own tracking.
    private func trackPanelVisibility() {
        withObservationTracking {
            _ = panel.isVisible
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trackPanelVisibility()
                self.syncHighlight()
            }
        }
    }

    private func syncHighlight() {
        // A turn later: the system's mouse-up unhighlight lands after the
        // click action runs, and setting ours first would lose to it. Read
        // inside the hop so a reordered hop can never apply a stale value.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.item.button?.highlight(self.panel.isVisible)
        }
    }

    /// Highlight our state now and once more a turn later. The system's own
    /// mouse-up unhighlight lands on one side of the click action or the
    /// other depending on release — setting on both sides means no ordering
    /// can show an off frame in between (ccp-ip27). The visibility observer
    /// still owns every non-click opener.
    private func syncHighlightSoon() {
        item.button?.highlight(panel.isVisible)
        syncHighlight()
    }

    private func updateFocusCountdown() {
        let store = FocusStore.shared
        // Drive the store's own tick: with the panel shut its ticker is
        // stopped, and without this a deadline that passes unseen leaves the
        // title wedged at 0:00 — remaining clamps at zero but never nils.
        // The store plays its own chime wherever the deadline is noticed.
        store.tick()
        // A paused stretch has no deadline coming — draw its frozen title
        // once and stop, rather than waking every second to repaint it.
        if store.isRunning {
            startCountdownTimer()
        } else {
            stopCountdownTimer()
        }
        // The edit pill owns the item's length, image and title while
        // editing; this leaves its capsule alone, and the editing observer
        // runs this again after the pill comes out, restoring the chrome.
        guard !panel.editor.isEditing else { return }
        guard let remaining = store.remaining(at: Date()) else {
            stopCountdownTimer()
            item.length = NSStatusItem.squareLength
            if let button = item.button {
                button.title = ""
                // Icon-only again: the image stands alone, centred.
                button.imagePosition = .imageOnly
            }
            return
        }
        item.length = NSStatusItem.variableLength
        if let button = item.button {
            // The countdown reads to the left of the icon, in monospaced
            // digits so the variable-length item never jitters as the
            // seconds turn over, and muted beside the bright icon. One font
            // for title and icon keeps them near the same baseline, and the
            // nudge finishes it: the text renders high next to the icon —
            // half a point measured off a 2x capture, another point by eye.
            let font = NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize, weight: .regular)
            let title = FocusStore.mmss(remaining)
            if button.title != title {
                button.attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .baselineOffset: Self.countdownBaselineNudge,
                ])
            }
            if button.imagePosition != .imageTrailing {
                button.imagePosition = .imageTrailing
            }
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

        // Dispatch only: the right-vs-left decision reads the event, never
        // panel state. The menu items below are where the menu is allowed
        // to touch the panel.
        let isRightClick = event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))

        if isRightClick {
            presentMenu()
        } else {
            if panel.editor.isEditing {
                finishEditing()
            } else {
                panel.toggle(from: sender)
                syncHighlightSoon()
            }
        }
    }

    /// Drop the menu the way a menu-backed status item does: assign it and
    /// synthetically click, so AppKit owns the tracking and the highlight
    /// while it is up. While the menu is assigned the button's action is not
    /// used (per `NSStatusItem.menu`), so a second press cannot re-enter
    /// here until the menu closes and the delegate clears it (ccp-nbg3).
    /// The pill calls this too: it covers the button wholesale, so
    /// right-clicks land in it and never on the button (ccp-lusi). Its
    /// Down-phase firing stays — a direct event override runs in no button
    /// tracking, which is the only thing Up-phase dispatch exists to avoid.
    private func presentMenu() {
        // The editing state may have changed synchronously (e.g. entering
        // edit via hold) while the observer rebuilding below is async.
        rebuildMenu()
        item.menu = menu
        item.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        item.menu = nil
        // The menu owned the highlight while tracking; put back whatever the
        // panel says (ccp-5es8). A chosen item that opened the panel reads
        // back visible here, so this never clears a highlight that is owed.
        item.button?.highlight(panel.isVisible)
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
