// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import SwiftUI

/// The pill's window, behind a seam so the show/hide bookkeeping is provable
/// without ordering real windows in tests.
protocol DropOverlayPanel: AnyObject {
    func show(anchoredTo anchor: NSRect?, content: DropOverlayRoot)
    func hide()
}

/// Borderless non-activating panel hanging below the menu-bar item. Never
/// made key: taking focus mid-drag would steal it from the app being dragged
/// from.
final class AppKitDropOverlayPanel: DropOverlayPanel {
    private var panel: NSPanel?
    private var host: NSHostingController<DropOverlayRoot>?

    func show(anchoredTo anchor: NSRect?, content: DropOverlayRoot) {
        let panel = ensurePanel(content: content)
        place(panel, anchor: anchor)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel(content: DropOverlayRoot) -> NSPanel {
        if let panel { return panel }
        let host = NSHostingController(rootView: content)
        host.view.wantsLayer = true
        host.sizingOptions = .preferredContentSize
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentViewController = host
        self.panel = panel
        self.host = host
        return panel
    }

    /// Centered on the status item, hanging below the menu bar and growing
    /// down; clamped to the anchor screen's visible frame. A nil anchor (no
    /// status frame to read) falls back to top-center of the main screen.
    private func place(_ panel: NSPanel, anchor: NSRect?) {
        guard let host else { return }
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        let screen = anchor.flatMap { frame in
            NSScreen.screens.first { $0.frame.intersects(frame) }
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(
            x: (anchor?.midX ?? visible.midX) - size.width / 2,
            y: visible.maxY - 4 - size.height
        )
        origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
        origin.y = min(max(visible.minY + 8, origin.y), visible.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
