// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit

/// The panel window itself: borderless, non-activating, above everything, and
/// present on whichever Space is in front.
///
/// Non-activating is the whole trick — clicking a toggle here must not pull
/// focus out of the app the user is working in, the way the system's own
/// Control Center doesn't. That costs the key window by default, so it is taken
/// back explicitly: a borderless panel is otherwise unable to become key and
/// nothing inside it would ever see a keystroke.
final class ControlPanelWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false

        // The window is a sheet of nothing holding cards that each blur the
        // desktop themselves; between them the desktop shows through
        // untouched. macOS derives the shadow from what the content actually
        // paints, so each card gets its own rather than the window getting one
        // rectangular shadow around the lot.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
}
