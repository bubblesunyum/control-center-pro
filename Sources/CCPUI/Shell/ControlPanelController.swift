// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import Observation
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
    private let content: NSHostingView<ControlPanel>
    private let arrangement: PanelArrangement
    private let editor = PanelEditor()

    /// The screen the panel is currently anchored to, kept so that growing by
    /// a lane mid-edit re-anchors against the same one it opened on.
    private var anchor: NSScreen?

    public private(set) var isVisible = false

    /// Watches for a click elsewhere or an Esc only while the panel is up.
    /// Built lazily because it dismisses this controller and so cannot be made
    /// before there is one.
    private lazy var dismissal = PanelDismissalMonitor { [weak self] reason in
        self?.dismiss(for: reason)
    }

    public init(arrangement: PanelArrangement) {
        self.arrangement = arrangement
        window = ControlPanelWindow(contentRect: NSRect(origin: .zero, size: .zero))

        // Transparent all the way through: each card blurs the desktop for
        // itself, and the space between them is desktop. A backdrop view here
        // would put the cards inside a container, and the container is the
        // thing this panel is deliberately not.
        content = NSHostingView(rootView: ControlPanel(arrangement: arrangement, editor: editor))
        window.contentView = content

        window.setContentSize(measuredContentSize)

        // Lay the SwiftUI graph out now rather than on the first open, where it
        // would land inside the 100ms.
        window.layoutIfNeeded()

        trackContentChanges()
    }

    /// Show the panel anchored to the top-right of the screen carrying the
    /// menu bar item that opened it.
    ///
    /// Multi-display placement is ccp-lr7.10; this asks the status item which
    /// screen it is on and falls back to the main one.
    public func show(from statusItemButton: NSStatusBarButton?) {
        present(from: statusItemButton, editing: false)
    }

    public func hide() {
        dismissal.stop()
        editor.stopEditing()
        window.orderOut(nil)
        isVisible = false
        // After the window is down, not before: a widget stopped first would
        // have the panel drawing a frame of whatever it left behind.
        arrangement.deactivate()
        // Whatever edit mode changed goes to disk now rather than 500ms into
        // a panel nobody can see.
        arrangement.flush()
    }

    /// Start edit mode without the long press that normally begins it.
    ///
    /// The same affordance as `--show-panel`, and there for the same reason: an
    /// agent can't press and hold, and edit mode is the half of the shell a
    /// screenshot has never been able to show.
    public func startEditing() {
        editor.startEditing()
    }

    /// Show the panel and enter edit mode in one step. When the panel is
    /// already visible this re-anchors to the screen that owns the status
    /// item that was clicked and then enters edit mode.
    public func showAndStartEditing(from statusItemButton: NSStatusBarButton?) {
        if isVisible {
            anchor = statusItemButton?.window?.screen ?? anchor ?? NSScreen.main
            withAnimation(.snappy) { editor.startEditing() }
            // `editor.isEditing` propagates to the SwiftUI graph asynchronously;
            // `place()` here sizes without the `EditingBar` and the
            // `trackContentChanges` task corrects it a frame later. That
            // one-frame growth is the cost of entering edit while open and is
            // preferable to a synchronous layout that reads stale `fittingSize`.
            place()
            return
        }
        present(from: statusItemButton, editing: true)
    }

    private func present(from statusItemButton: NSStatusBarButton?, editing: Bool) {
        anchor = statusItemButton?.window?.screen ?? NSScreen.main
        arrangement.activate()
        if editing { editor.startEditing() }
        place()
        window.orderFrontRegardless()
        window.makeKey()
        isVisible = true
        dismissal.start()
    }

    public func toggle(from statusItemButton: NSStatusBarButton?) {
        isVisible ? hide() : show(from: statusItemButton)
    }

    private func dismiss(for reason: PanelDismissalMonitor.Reason) {
        // Esc backs out of one thing at a time, and while the panel is being
        // rearranged the thing in front is edit mode. A click in another app
        // is not a step back — the user has gone somewhere else.
        if reason == .escapeKey, editor.isEditing {
            withAnimation(.snappy) { editor.stopEditing() }
        } else {
            hide()
        }
    }

    // MARK: - Placement

    /// Anchor the panel top-right of its screen at whatever size it currently
    /// wants. Called on every open, and again whenever edit mode changes what
    /// the panel holds — a dropped lane makes it a column wider, and a window
    /// that stayed its old size would simply crop the new one.
    private func place() {
        guard let visible = anchor?.visibleFrame else { return }

        // What the display can show is edit mode's limit too, so it is told
        // here rather than working it out from a screen it has no business
        // knowing about.
        editor.laneCapacity = Layout.laneCapacity(inWidth: visible.width)

        let size = sizeFitting(visible)
        window.setFrame(
            NSRect(
                x: visible.maxX - size.width - Layout.panelInset,
                y: visible.maxY - size.height - Layout.panelInset,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }

    /// What the lanes are asking for, measured now. Re-measured rather than
    /// remembered: edit mode changes it, and a panel cut down to fit a small
    /// display must come back whole on a large one.
    private var measuredContentSize: NSSize {
        content.layoutSubtreeIfNeeded()
        return content.fittingSize
    }

    /// The panel never grows past the space it is shown in: a panel wider than
    /// the display has a lane hanging off the far edge with nothing to say it
    /// is there. Edit mode won't build one (`Layout.laneCapacity`); this is
    /// what catches an arrangement carried over from a wider display.
    private func sizeFitting(_ visible: NSRect) -> NSSize {
        let wanted = measuredContentSize
        return NSSize(
            width: min(wanted.width, visible.width - Layout.panelInset * 2),
            height: min(wanted.height, visible.height - Layout.panelInset * 2)
        )
    }

    /// Re-place the panel whenever what it holds changes shape.
    ///
    /// Observation reports a change as it is about to happen and then stops
    /// watching, so this reads the new value a turn later and arms itself
    /// again — both halves are required, and dropping either gives a panel
    /// that resizes exactly once.
    private func trackContentChanges() {
        withObservationTracking {
            _ = arrangement.layout
            _ = editor.isEditing
            // What was picked up, not where it is: this is a window resize,
            // and it belongs at the two ends of a drag rather than in every
            // frame of one.
            _ = editor.lifted
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                trackContentChanges()
                if isVisible { place() }
            }
        }
    }
}
