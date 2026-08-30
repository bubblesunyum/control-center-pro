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
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
