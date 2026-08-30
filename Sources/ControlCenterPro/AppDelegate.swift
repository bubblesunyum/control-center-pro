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

        // The starting arrangement, until the persisted layout lands in
        // ccp-lr7.2. Ids the registry doesn't know are dropped, which is the
        // same thing a stored layout from another build has to survive.
        let seed: [[WidgetID]] = [
            ["system-stats", "clipboard"],
            ["quick-toggles", "now-playing", "audio-mixer"],
        ]
        let lanes = seed.map { $0.compactMap(registry.makeInstance(of:)) }

        let panel = ControlPanelController(lanes: lanes)
        statusItem = StatusItemController(panel: panel)

        // An agent can't click a menu bar item, and a screenshot of a panel
        // nobody opened is a screenshot of the desktop. This is how the smoke
        // run and the design review get to see the thing.
        if CommandLine.arguments.contains("--show-panel") {
            panel.show(from: nil)
        }
    }
}
