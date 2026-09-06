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

    /// The screen the panel is currently seated on. The window covers it
    /// wholesale, so this is the seat kept across display changes while open.
    private var anchor: NSScreen?

    /// The lanes' box in panel space, reported by the view. The window is
    /// screen-sized and lets clicks through outside the panel's own content,
    /// so the pointer is hit-tested against this (translated to screen space)
    /// to decide what falls through.
    private var lanesFrame: CGRect = .zero
    /// Whether a lanes frame has arrived since the panel opened. The first
    /// evaluation must assume interactive: a zero rect would let a click
    /// through onto the app below and dismiss the panel on its first frame.
    private var lanesFrameValid = false

    /// The pointer watchers while the panel is up — a local monitor and a
    /// global one, because each is deaf where the other hears: the global one
    /// never sees moves over our own window, the local one never sees moves
    /// past it. Same lifetime as the dismissal monitor.
    private var mouseThroughMonitors: [Any] = []

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
        //
        // Seeded empty: the real root reports the lanes' frame back through
        // `self`, which doesn't exist until `content` does.
        content = NSHostingView(rootView: AnyView(EmptyView()))
        window.contentView = content
        let reportFrame: (CGRect) -> Void = { [weak self] frame in
            Task { @MainActor in self?.lanesFrameDidChange(frame) }
        }

        // Wire the panel's widgets to the controller's dismiss + paste so a
        // clipboard row can hide immediately and then paste into the app that
        // was frontmost before the panel opened.
        let hide: () -> Void = { [weak self] in self?.hide() }
        let paste: () -> Void = { [weak self] in self?.pasteIntoPreviousApp() }
        content.rootView = AnyView(ControlPanel(
            arrangement: arrangement,
            editor: editor,
            onLanesFrame: reportFrame
        )
        .environment(\.hidePanel, hide)
        .environment(\.pasteIntoPreviousApp, paste))

        // Lay the SwiftUI graph out now rather than on the first open, where it
        // would land inside the 100ms.
        window.layoutIfNeeded()

        trackContentChanges()
        trackMouseThroughContent()
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
        stopMouseThrough()
        editor.stopEditing()
        window.orderOut(nil)
        isVisible = false
        // After the window is down, not before: a widget stopped first would
        // have the panel drawing a frame of whatever it left behind.
        arrangement.deactivate()
        // Whatever edit mode changed goes to disk now rather than 500ms into
        // a panel nobody can see.
        arrangement.flush()
        StickyStore.shared.flush()
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
            place()
            return
        }
        present(from: statusItemButton, editing: true)
    }

    private func present(from statusItemButton: NSStatusBarButton?, editing: Bool) {
        anchor = statusItemButton?.window?.screen ?? NSScreen.main
        lanesFrameValid = false
        rememberPasteTarget()
        arrangement.activate()
        if editing { editor.startEditing() }
        place()
        window.orderFrontRegardless()
        window.makeKey()
        isVisible = true
        dismissal.start()
        startMouseThrough()
    }

    public func toggle(from statusItemButton: NSStatusBarButton?) {
        isVisible ? hide() : show(from: statusItemButton)
    }

    /// A new sticky at the window's center, opening the panel first when it
    /// is down — a note nobody can see is a note nobody wrote.
    public func newSticky() {
        if !isVisible {
            show(from: nil)
        }
        let size = window.frame.size
        StickyStore.shared.add(x: size.width / 2, y: size.height / 2)
    }

    private func dismiss(for reason: PanelDismissalMonitor.Reason) {
        // Esc backs out of one thing at a time, and a keystroke in flight is
        // the thing in front: a sticky (or lane note) being typed in resigns
        // first, edit mode second, the panel last. A sticky's delete
        // confirmation answers Esc itself — the panel must not vanish from
        // under the question.
        if reason == .escapeKey, StickyStore.shared.isConfirmingDelete { return }
        if reason == .escapeKey, window.firstResponder is NSTextView {
            window.makeFirstResponder(nil)
            return
        }
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

    /// Cut the window to the anchor screen. The window is the screen, not the
    /// lanes: stickies live anywhere in it, and clicks outside the panel's
    /// own content fall through to whatever is below (see mouse-through).
    /// The lanes keep their top-right seat inside, via the view's own insets.
    private func place() {
        guard let visible = anchor?.visibleFrame else { return }

        // What the display can show is edit mode's limit too, so it is told
        // here rather than working it out from a screen it has no business
        // knowing about.
        editor.displayWidth = visible.width

        window.setFrame(visible, display: true)
        reclaimStickies()
    }

    /// Pull any sticky whose header left the window back to reachability.
    /// Drifts off-screen are allowed, stranded notes are not: without a
    /// reachable pixel the only recovery is hand-editing the file. Runs on
    /// seat changes, never mid-drag.
    private func reclaimStickies() {
        let bounds = CGRect(origin: .zero, size: window.frame.size)
        for sticky in StickyStore.shared.visible {
            let clamped = StickyCard.clampedCenter(
                CGPoint(x: sticky.x, y: sticky.y),
                in: bounds
            )
            if clamped.x != sticky.x || clamped.y != sticky.y {
                StickyStore.shared.move(sticky.id, toX: clamped.x, toY: clamped.y)
            }
        }
    }

    // MARK: - Mouse-through

    /// The window covers the screen, but only the lanes, the stickies, and an
    /// open gallery are the panel's: everywhere else the window ignores the
    /// pointer so clicks reach the app below (and the dismissal monitor sees
    /// them land there).
    private func lanesFrameDidChange(_ frame: CGRect) {
        lanesFrame = frame
        lanesFrameValid = true
        updateMouseThrough(at: NSEvent.mouseLocation)
    }

    private func startMouseThrough() {
        stopMouseThrough()
        updateMouseThrough(at: NSEvent.mouseLocation)
        let hop: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateMouseThrough(at: NSEvent.mouseLocation)
            }
        }
        // The pair, not either half: the global monitor is deaf over our own
        // window, the local one past it. In-repo precedent is the local/global
        // click pair the dismissal path already relies on.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: hop) {
            mouseThroughMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { hop($0); return $0 }) {
            mouseThroughMonitors.append(local)
        }
    }

    private func stopMouseThrough() {
        mouseThroughMonitors.forEach(NSEvent.removeMonitor)
        mouseThroughMonitors.removeAll()
        window.ignoresMouseEvents = false
    }

    private func updateMouseThrough(at screenPoint: CGPoint) {
        guard isVisible else { return }
        // A delete confirmation open is modal-ish: the window takes the
        // pointer so the dialog answers clicks instead of the app below.
        let interactive = !lanesFrameValid || StickyStore.shared.isConfirmingDelete || Self.isInteractive(
            at: screenPoint,
            windowFrame: window.frame,
            lanesFrame: lanesFrame,
            stickies: editor.isEditing ? [] : StickyStore.shared.visible,
            galleryOpen: editor.isShowingGallery
        )
        if window.ignoresMouseEvents == interactive {
            window.ignoresMouseEvents = !interactive
        }
    }

    /// Re-evaluate click-through when the interactive set itself changes —
    /// gallery, edit mode, and every sticky mutation — rather than waiting
    /// for the next mouse move that may never come.
    private func trackMouseThroughContent() {
        withObservationTracking {
            _ = StickyStore.shared.stickies
            _ = StickyStore.shared.isConfirmingDelete
            _ = editor.isEditing
            _ = editor.isShowingGallery
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trackMouseThroughContent()
                self.updateMouseThrough(at: NSEvent.mouseLocation)
            }
        }
    }

    /// Whether the screen point is the panel's own content. Pure so the
    /// hit-test math is provable without ordering windows: panel rects are
    /// top-leading origin, screen points are bottom-leading. Sticky geometry
    /// reads through the card's own frame helper — one definition shared with
    /// the desk and the drag guard.
    nonisolated static func isInteractive(
        at screenPoint: CGPoint,
        windowFrame: CGRect,
        lanesFrame: CGRect,
        stickies: [Sticky],
        galleryOpen: Bool
    ) -> Bool {
        if galleryOpen { return true }
        let toScreen = { (panel: CGRect) in CGRect(
            x: windowFrame.minX + panel.minX,
            y: windowFrame.maxY - panel.maxY,
            width: panel.width,
            height: panel.height
        ) }
        if toScreen(lanesFrame).contains(screenPoint) { return true }
        return stickies.contains { sticky in
            toScreen(StickyCard.frame(center: CGPoint(x: sticky.x, y: sticky.y)))
                .contains(screenPoint)
        }
    }

    // MARK: - Content tracking

    /// Re-place the panel whenever what it holds changes shape.
    ///
    /// Observation reports a change as it is about to happen and then stops
    /// watching, so this reads the new value a turn later and arms itself
    /// again — both halves are required, and dropping either gives a panel
    /// that resizes exactly once.
    private func trackContentChanges() {
        trackLayoutChanges()
    }

    private func trackLayoutChanges() {
        withObservationTracking {
            _ = arrangement.layout
            _ = editor.isEditing
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trackLayoutChanges()
                // The window is the screen, so content changes never move it;
                // re-asserting the frame here keeps the seat if the display
                // changed while open. Skipped mid-drag: even a same-frame set
                // is churn the finger doesn't need.
                guard self.isVisible, !self.editor.isDragging else { return }
                self.place()
            }
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
