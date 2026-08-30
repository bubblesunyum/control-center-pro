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
    private let arrangement: PanelArrangement
    /// What the lanes actually asked for, measured once. `show` clamps this to
    /// the screen rather than remeasuring, so a panel that had to be cut down
    /// on a small display comes back whole on a large one.
    private let contentSize: NSSize

    public private(set) var isVisible = false

    /// Watches for a click elsewhere or an Esc only while the panel is up.
    /// Built lazily because it dismisses this controller and so cannot be made
    /// before there is one.
    private lazy var dismissal = PanelDismissalMonitor { [weak self] in
        self?.hide()
    }

    public init(arrangement: PanelArrangement) {
        self.arrangement = arrangement
        window = ControlPanelWindow(contentRect: NSRect(origin: .zero, size: .zero))

        // Transparent all the way through: each card blurs the desktop for
        // itself, and the space between them is desktop. A backdrop view here
        // would put the cards inside a container, and the container is the
        // thing this panel is deliberately not.
        let content = NSHostingView(rootView: ControlPanel(arrangement: arrangement))
        window.contentView = content

        // The panel is exactly as big as what it holds: a lane more is a column
        // wider, a taller widget is a taller panel, and no arithmetic here has
        // to agree with the layout SwiftUI actually performed.
        content.layoutSubtreeIfNeeded()
        contentSize = content.fittingSize
        window.setContentSize(contentSize)

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
        let size = sizeFitting(visible)
        if window.frame.size != size { window.setContentSize(size) }
        window.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - Layout.panelInset,
            y: visible.maxY - size.height - Layout.panelInset
        ))

        arrangement.activate()
        window.orderFrontRegardless()
        window.makeKey()
        isVisible = true
        dismissal.start()
    }

    /// The panel never grows past the space it is shown in: a panel wider than
    /// the display has a lane hanging off the far edge with nothing to say it
    /// is there. Cards beyond the edge are cut rather than reflowed — ccp-p6g
    /// decides whether the real answer is scrolling or a lane cap.
    private func sizeFitting(_ visible: NSRect) -> NSSize {
        NSSize(
            width: min(contentSize.width, visible.width - Layout.panelInset * 2),
            height: min(contentSize.height, visible.height - Layout.panelInset * 2)
        )
    }

    public func hide() {
        dismissal.stop()
        window.orderOut(nil)
        isVisible = false
        // After the window is down, not before: a widget stopped first would
        // have the panel drawing a frame of whatever it left behind.
        arrangement.deactivate()
    }

    public func toggle(from statusItemButton: NSStatusBarButton?) {
        isVisible ? hide() : show(from: statusItemButton)
    }
}
