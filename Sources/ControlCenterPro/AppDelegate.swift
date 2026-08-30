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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let registry = makeStandardRegistry()
        let store = JSONFileStore(filename: "layout.json", default: standardLayout)
        let layout = store.load().normalized()

        // Written back on every launch so the file always describes what is on
        // screen: it is how the arrangement exists at all before anyone has
        // edited one, and normalizing is not a change worth keeping in memory
        // only. A layout naming widgets this build lacks survives the round
        // trip intact. Nothing to do if the write fails — the panel is already
        // built, and the next launch reads the defaults again.
        try? store.save(layout)

        let panel = ControlPanelController(lanes: registry.resolve(layout))
        statusItem = StatusItemController(panel: panel)

        // An agent can't click a menu bar item, and a screenshot of a panel
        // nobody opened is a screenshot of the desktop. This is how the smoke
        // run and the design review get to see the thing.
        if CommandLine.arguments.contains("--show-panel") {
            panel.show(from: nil)
        }
    }
}
