// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import Carbon.HIToolbox
import CCPKit
import CoreGraphics
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
    private let content: NSHostingView<AnyView>
    public let arrangement: PanelArrangement
    public let editor = PanelEditor()

    /// The screen the panel is currently anchored to, kept so that growing by
    /// a lane mid-edit re-anchors against the same one it opened on.
    private var anchor: NSScreen?
    private var previousOffer: Int?

    public private(set) var isVisible = false

    /// The app that was frontmost when the panel was shown — where a clipboard
    /// paste should land after the panel hides.
    private var pasteTargetApp: NSRunningApplication?

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
        let baseView = ControlPanel(arrangement: arrangement, editor: editor)
        content = NSHostingView(rootView: AnyView(baseView))
        window.contentView = content

        // Wire the panel's widgets to the controller's dismiss + paste so a
        // clipboard row can hide immediately and then paste into the app that
        // was frontmost before the panel opened.
        let hide: () -> Void = { [weak self] in self?.hide() }
        let paste: () -> Void = { [weak self] in self?.pasteIntoPreviousApp() }
        let decorated = baseView
            .environment(\.hidePanel, hide)
            .environment(\.pasteIntoPreviousApp, paste)
        content.rootView = AnyView(decorated)

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
        previousOffer = nil
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

    /// Leave edit mode while keeping the panel visible.
    public func stopEditing() {
        withAnimation(.snappy) { editor.stopEditing() }
        place()
    }

    /// Leave edit mode but keep the gallery open — the menu bar checkmark
    /// uses this so an open gallery isn't lost when confirming the layout.
    public func finishEditingKeepingGallery() {
        withAnimation(.snappy) { editor.finishEditingPreservingGallery() }
        place()
    }

    /// Present the widget gallery. The panel must be visible; if it is not,
    /// it is shown first in edit mode.
    public func showGallery() {
        if !isVisible {
            showAndStartEditing(from: nil)
        } else if !editor.isEditing {
            withAnimation(.snappy) { editor.startEditing() }
            place()
        }
        editor.isShowingGallery = true
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
        previousOffer = nil
        rememberPasteTarget()
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
        } else if reason == .clickElsewhere, editor.isEditing {
            // Click outside while editing — exit edit but keep the panel and
            // an open gallery. The menu bar checkmark also uses this path via
            // the status item's click handler; without it the global monitor
            // would hide the panel and dismiss the gallery.
            if editor.isShowingGallery {
                finishEditingKeepingGallery()
            } else {
                stopEditing()
            }
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
        editor.displayWidth = visible.width

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
    /// is there. Edit mode won't build one (`Layout.fitsAnotherLane`); this is
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
        trackLayoutChanges()
        trackLiftChanges()
        trackNewLaneChanges()
        trackResizeChanges()
    }

    private func trackLayoutChanges() {
        withObservationTracking {
            _ = arrangement.layout
            _ = editor.isEditing
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trackLayoutChanges()
                // Layout is frozen while dragging (one mutation on drop, gap
                // is visual only). Resizing the window mid-drag as the source
                // lane collapses shifts the .panel coordinate space under the
                // finger and clips the placeholder.
                guard self.isVisible, !self.editor.isDragging else { return }
                self.place()
            }
        }
    }

    private func trackLiftChanges() {
        withObservationTracking {
            _ = editor.lifted
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trackLiftChanges()
                guard self.isVisible else { return }
                // Lift now keeps the gap at the original spot, so the grid
                // doesn't collapse and the window height stays stable. No
                // window move at lift — new-lane growth is deferred until the
                // finger actually hovers a gap (see trackNewLaneChanges),
                // which is the only stable moment to grow.
                self.place()
                if !self.editor.isDragging {
                    self.previousOffer = nil
                }
            }
        }
    }

    private func trackNewLaneChanges() {
        withObservationTracking {
            _ = editor.previewLanding
            _ = arrangement.laneWidths
            _ = editor.displayWidth
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trackNewLaneChanges()
                guard self.isVisible, self.editor.isDragging else { return }
                let offer = self.editor.offeredNewLaneAt(beside: self.arrangement.laneWidths)
                guard offer != self.previousOffer else { return }
                let previous = self.previousOffer
                self.previousOffer = offer
                // Growing leftward moves the panel's origin left by one lane
                // width, so the finger's panel-local x grows by that much for
                // the same screen point. Nudge the frozen snapshot so the gap
                // stays under the ghost instead of jumping — per lane, because
                // only the lanes at and right of the opening move inside the
                // panel while the ones left of it stay. Animate the window
                // with the same 0.2s as the gap so the ghost doesn't drift.
                let dx = Layout.laneWidth + Space.oneHalf
                if previous == nil, let at = offer {
                    self.place(animated: true)
                    self.editor.shiftSnapshot(dx: dx, newLaneAt: at)
                } else if offer == nil, let at = previous {
                    self.place(animated: true)
                    self.editor.shiftSnapshot(dx: -dx, newLaneAt: at)
                } else if let from = previous, let to = offer {
                    // One gap to another with no resize between: rebase the
                    // shift onto the new opening. Unreachable by a continuous
                    // finger (every path between gaps crosses a lane, which
                    // un-offers first), but cheap to keep truthful.
                    self.editor.shiftSnapshot(dx: -dx, newLaneAt: from)
                    self.editor.shiftSnapshot(dx: dx, newLaneAt: to)
                }
            }
        }
    }

    /// A resize previews without touching the layout, so none of the trackers
    /// above fire for it — and the lane would draw its preview in a window
    /// still cut for the old size. The drag counts in translation, not panel
    /// coordinates, so growing the window under the finger breaks no math.
    private func trackResizeChanges() {
        withObservationTracking {
            _ = editor.resizePreview
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trackResizeChanges()
                guard self.isVisible else { return }
                // In flight the window tracks the finger every frame: an
                // animated re-place here would stack a 0.2s ease on each tick
                // and smear behind the card. The settle — preview gone on
                // release or cancel — is the one that animates, gliding the
                // window onto the snapped size with the card.
                if self.editor.resizePreview != nil {
                    self.place()
                } else {
                    self.place(animated: true)
                }
            }
        }
    }

    private func place(animated: Bool) {
        guard let visible = anchor?.visibleFrame else { return }
        editor.displayWidth = visible.width
        let size = sizeFitting(visible)
        let frame = NSRect(
            x: visible.maxX - size.width - Layout.panelInset,
            y: visible.maxY - size.height - Layout.panelInset,
            width: size.width,
            height: size.height
        )
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    // MARK: - Clipboard paste

    private func rememberPasteTarget() {
        let ownBundleID = Bundle.main.bundleIdentifier
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != ownBundleID,
              app.activationPolicy == .regular,
              !app.isTerminated
        else {
            pasteTargetApp = nil
            return
        }
        pasteTargetApp = app
    }

    private func pasteIntoPreviousApp() {
        guard let app = pasteTargetApp, !app.isTerminated else { return }
        pasteTargetApp = nil
        app.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Self.postPasteShortcut()
        }
    }

    private static func postPasteShortcut() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source,
                                    virtualKey: CGKeyCode(kVK_ANSI_V),
                                    keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source,
                                  virtualKey: CGKeyCode(kVK_ANSI_V),
                                  keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
