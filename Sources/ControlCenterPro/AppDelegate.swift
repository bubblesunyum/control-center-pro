// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import CCPUI
import Observation
import VorssaintEngines

/// Wires the app together: the widgets it offers, the arrangement they start
/// in, the panel that draws them, and the menu bar item that opens it.
///
/// This is the only place that knows all four, which is what keeps the registry
/// from having to reach for the interface and the shell from having to know
/// what a widget is.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var arrangement: PanelArrangement?
    private var settings: SettingsStore?
    private var craft: CraftConnectionModel?
    private var hotkey: GlobalHotkey?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        BridgedDefaults.register()
        let registry = makeStandardRegistry()
        let store = JSONFileStore(filename: "layout.json", default: standardLayout)
        let arrangement = PanelArrangement(
            store.load(),
            registry: registry,
            autosave: LayoutAutosave(store: store)
        )
        self.arrangement = arrangement

        let panel = ControlPanelController(arrangement: arrangement)
        let settings = SettingsStore()
        self.settings = settings

        let hotkey = GlobalHotkey()
        self.hotkey = hotkey
        hotkey.onPress = { [weak self] in
            panel.toggle(from: self?.statusItem?.button)
        }
        hotkey.use(settings.panelShortcut)
        trackShortcutChanges()

        let craftConnection = CraftConnectionModel()
        self.craft = craftConnection

        let settingsWindow = SettingsWindowController(settings: settings,
                                                        craft: craftConnection,
                                                        hotkey: hotkey)
        self.settingsWindow = settingsWindow
        statusItem = StatusItemController(panel: panel, settingsWindow: settingsWindow)

        // An agent can't click a menu bar item, and a screenshot of a panel
        // nobody opened is a screenshot of the desktop. This is how the smoke
        // run and the design review get to see the thing.
        if CommandLine.arguments.contains("--show-panel") {
            panel.show(from: nil)
        }
        if CommandLine.arguments.contains("--edit-mode") {
            panel.startEditing()
        }
        if CommandLine.arguments.contains("--show-settings") {
            settingsWindow.show()
        }
        if CommandLine.arguments.contains("--show-shelf") {
            ShelfWindowController.shared.show()
        }
    }

    /// Keep the registration on whatever the user last chose.
    ///
    /// Observation reports a change as it is about to happen and then stops
    /// watching, so this reads the new value a turn later and arms itself
    /// again — the same shape the panel uses to follow its content.
    private func trackShortcutChanges() {
        withObservationTracking {
            _ = settings?.panelShortcut
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                trackShortcutChanges()
                hotkey?.use(settings?.panelShortcut)
            }
        }
    }

    /// The autosave is deliberately lazy, so quitting is the one moment it has
    /// to stop being.
    func applicationWillTerminate(_ notification: Notification) {
        arrangement?.flush()
        ShelfStore.shared.flush()
    }
}
