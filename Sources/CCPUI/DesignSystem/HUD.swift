// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import SwiftUI

/// The panel's one transient toast: an icon, a short message, top-center of
/// the screen holding the mouse, gone after a beat.
///
/// Each widget previously kept its own private copy, and the two had drifted:
/// fixed fonts on one side, semantic on the other, a `.main` anchor on one
/// side, a mouse-screen anchor on the other. One owner so the call-sites
/// can't drift apart again.
public enum HUD {
    private static var panel: NSPanel?
    private static var dismissWork: DispatchWorkItem?
    private static var generation = 0

    public static func show(icon: String, message: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { show(icon: icon, message: message) }
            return
        }
        let content = HStack(spacing: Space.one) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(message)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: Layout.hudMessageMaxWidth, alignment: .leading)
        }
        .padding(.horizontal, Space.oneHalf)
        .padding(.vertical, Space.one)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        present(AnyView(content), dismissAfter: Layout.hudDismissDelay)
    }

    private static func present(_ content: AnyView, dismissAfter: Double) {
        let host = NSHostingController(rootView: content)
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        let panel = ensurePanel()
        panel.contentViewController = host
        let frame: NSRect
        // The panel opens top-right, so anchor to the screen holding the
        // mouse rather than whichever screen is main.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            frame = NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - Layout.hudTopOffset, width: size.width, height: size.height)
        } else {
            frame = NSRect(x: Layout.hudFallbackOrigin, y: Layout.hudFallbackOrigin, width: size.width, height: size.height)
        }
        panel.setFrame(frame, display: true)
        generation += 1
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Layout.hudFadeInDuration
            panel.animator().alphaValue = 1
        }
        dismissWork?.cancel()
        let work = DispatchWorkItem { dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter, execute: work)
    }

    private static func dismiss() {
        guard let panel else { return }
        let dismissed = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Layout.hudFadeOutDuration
            panel.animator().alphaValue = 0
        }, completionHandler: {
            guard generation == dismissed else { return }
            panel.orderOut(nil)
            panel.contentViewController = nil
            dismissWork = nil
        })
    }

    private static func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        self.panel = panel
        return panel
    }
}
