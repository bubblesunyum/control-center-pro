// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import SwiftUI

/// Owns the panel window and decides where and when it appears.
///
/// The window and its hosting view are built once, at launch, and never torn
/// down: the panel's budget is under 100ms perceived, and the first open is the
/// one that would otherwise pay for creating a window, a hosting view and a
/// SwiftUI graph all at once.
@MainActor
public final class ControlPanelController {
    private let window: ControlPanelWindow

    public private(set) var isVisible = false

    public init(lanes: [[WidgetInstance]]) {
        window = ControlPanelWindow(contentRect: NSRect(origin: .zero, size: .zero))

        // Transparent all the way through: each card blurs the desktop for
        // itself, and the space between them is desktop. A backdrop view here
        // would put the cards inside a container, and the container is the
        // thing this panel is deliberately not.
        let content = NSHostingView(rootView: ControlPanel(lanes: lanes))
        window.contentView = content

        // The panel is exactly as big as what it holds: a lane more is a column
        // wider, a taller widget is a taller panel, and no arithmetic here has
        // to agree with the layout SwiftUI actually performed.
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)

        // Lay the SwiftUI graph out now rather than on the first open, where it
        // would land inside the 100ms.
        window.layoutIfNeeded()
    }

    /// Show the panel anchored to the top-right of the screen carrying the
    /// menu bar item that opened it.
    ///
    /// Multi-display placement is ccp-lr7.10; this asks the status item which
    /// screen it is on and falls back to the main one.
    public func show(from statusItemButton: NSStatusBarButton?) {
        let screen = statusItemButton?.window?.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        // visibleFrame already excludes the menu bar, including when it is set
        // to auto-hide and currently hidden.
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - Layout.panelInset,
            y: visible.maxY - size.height - Layout.panelInset
        ))

        window.orderFrontRegardless()
        window.makeKey()
        isVisible = true
    }

    public func hide() {
        window.orderOut(nil)
        isVisible = false
    }

    public func toggle(from statusItemButton: NSStatusBarButton?) {
        isVisible ? hide() : show(from: statusItemButton)
    }
}
