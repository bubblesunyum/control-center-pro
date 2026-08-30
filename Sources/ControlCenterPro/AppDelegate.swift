// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import CCPUI

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let registry = makeStandardRegistry()
        let store = JSONFileStore(filename: "layout.json", default: standardLayout)
        let arrangement = PanelArrangement(
            store.load(),
            registry: registry,
            autosave: LayoutAutosave(store: store)
        )
        self.arrangement = arrangement

        let panel = ControlPanelController(arrangement: arrangement)
        statusItem = StatusItemController(panel: panel)

        // An agent can't click a menu bar item, and a screenshot of a panel
        // nobody opened is a screenshot of the desktop. This is how the smoke
        // run and the design review get to see the thing.
        if CommandLine.arguments.contains("--show-panel") {
            panel.show(from: nil)
        }
        if CommandLine.arguments.contains("--edit-mode") {
            panel.startEditing()
        }
    }

    /// The autosave is deliberately lazy, so quitting is the one moment it has
    /// to stop being.
    func applicationWillTerminate(_ notification: Notification) {
        arrangement?.flush()
    }
}
