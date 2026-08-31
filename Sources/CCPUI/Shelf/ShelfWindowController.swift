// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import SwiftUI

/// The floating shelf window — a compact, non-activating panel that holds files,
/// text snippets, links and images you drop on it to drag back out elsewhere.
///
/// Copied from Vorssaint's `ShelfService` panel + `ShelfView` layout, but the
/// triggers are CCP's own: no global hotkey, no shake detector, no docked pill,
/// no edge peek. The widget on the CCP dashboard is what summons this — Command
/// + Option + S does not. The visual language (304pt wide, 18pt radius, glass
/// card with thin stroke, 78×88 tiles) stays as close to upstream as the CCP
/// design system allows so the copy is honest.
@MainActor
@Observable
public final class ShelfWindowController {
    public static let shared = ShelfWindowController()

    private var panel: NSPanel?
    private var host: NSHostingController<ShelfPanelRoot>?
    nonisolated(unsafe) private var moveObserver: NSObjectProtocol?

    /// Position the next show at the mouse, unless it has been moved.
    private var hasBeenMoved = false

    private init() {}

    deinit {
        if let token = moveObserver { NotificationCenter.default.removeObserver(token) }
    }

    public var isVisible: Bool { panel?.isVisible == true }

    public func toggle() {
        isVisible ? hide() : show()
    }

    public func show(at anchor: NSRect? = nil) {
        let panel = ensurePanel()
        // Re-clamp even after a move: an external display gone or a resolution
        // change can leave the saved origin off-screen forever.
        if !hasBeenMoved || !isOnScreen(panel.frame) {
            position(panel, anchor: anchor)
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        // Pinning semantics: while pinned the window stays even if focus leaves;
        // AppKit's .nonactivatingPanel already hides on deactivate = false, so
        // nothing extra to manage there. The pin just suppresses auto-hide that
        // we don't have yet — kept for parity.
    }

    private func isOnScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(frame) }
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let root = ShelfPanelRoot { [weak self] in self?.hide() }
        let host = NSHostingController(rootView: root)
        host.view.wantsLayer = true
        host.view.layer?.cornerRadius = Radius.card
        host.sizingOptions = .preferredContentSize

        let panel = ShelfFloatingPanel(contentRect: .zero,
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentViewController = host
        panel.isMovableByWindowBackground = false

        // Track moves so we don't snap back to the mouse after the user placed it.
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                                              object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.hasBeenMoved = true }
        }

        self.panel = panel
        self.host = host
        return panel
    }

    private func position(_ panel: NSPanel, anchor: NSRect?) {
        guard let host else { return }
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        let target: NSPoint
        if let anchor {
            target = NSPoint(x: anchor.midX - size.width / 2,
                             y: anchor.maxY + 8)
        } else {
            let mouse = NSEvent.mouseLocation
            // Center on mouse, slightly offset so cursor doesn't start over the header drag handle
            target = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)
        }
        // Clamp to visible frame so it never opens off-screen on a small display
        let visible = NSScreen.screens.first(where: { $0.frame.contains(target) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var frame = NSRect(origin: target, size: size)
        frame.origin.x = min(max(visible.minX + 8, frame.origin.x), visible.maxX - frame.width - 8)
        frame.origin.y = min(max(visible.minY + 8, frame.origin.y), visible.maxY - frame.height - 8)
        panel.setFrame(frame, display: true)
    }

    private final class ShelfFloatingPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) {
            ShelfWindowController.shared.hide()
        }
    }
}

/// Thin root that injects the shared store into the shelf view and forwards
/// dismissal.
private struct ShelfPanelRoot: View {
    var onDismiss: () -> Void
    @State private var store = ShelfStore.shared

    var body: some View {
        ShelfView(onDismiss: onDismiss)
            .environment(store)
    }
}
