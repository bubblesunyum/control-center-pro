// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPUI

/// The menu bar item, and the one gesture the app has: click to show the panel,
/// click again to put it away.
@MainActor
final class StatusItemController {
    private let item: NSStatusItem
    private let panel: ControlPanelController

    init(panel: ControlPanelController) {
        self.panel = panel
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = item.button else { return }
        button.image = NSImage(
            systemSymbolName: "square.grid.2x2",
            accessibilityDescription: "Control Center Pro"
        )
        button.target = self
        button.action = #selector(togglePanel)
    }

    @objc private func togglePanel() {
        panel.toggle(from: item.button)
    }
}
