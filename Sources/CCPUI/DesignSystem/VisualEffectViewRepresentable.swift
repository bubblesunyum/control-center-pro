// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import SwiftUI

/// Real blur of whatever is behind the window, for use as a SwiftUI background.
///
/// SwiftUI's own materials blur what is already inside the window and nothing
/// else, so over a transparent panel one renders as a faint tint you can read
/// straight through. This is the only thing that samples the desktop.
struct VisualEffectViewRepresentable: NSViewRepresentable {
    // .hudWindow reads as Control Center frost vs .popover's sheet tint
    // (see Vorssaint's HUDBackdropMaterial — always .hudWindow for behind-window).
    var material: NSVisualEffectView.Material = .hudWindow
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        apply(to: view)
    }

    private func apply(to view: NSVisualEffectView) {
        // SwiftUI's .clipShape rounds the drawn content but does not clip an
        // NSVisualEffectView's behind-window blur — the blur and the window's
        // shadow keep the full rectangular bounds and read as a faint outline
        // just outside the rounded card (see Vorssaint's HUDBackdropMaterial).
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = cornerRadius > 0
    }
}
