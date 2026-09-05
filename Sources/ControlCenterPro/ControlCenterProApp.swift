// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPUI

/// The entry point.
///
/// AppKit rather than a SwiftUI `App` scene: the panel is a non-activating
/// `NSPanel` positioned against the menu bar, which is not something a
/// `WindowGroup` or `MenuBarExtra` will give up.
@main
@MainActor
struct ControlCenterProApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate

        // No Dock tile and no main window. The bundle's Info.plist says the
        // same with LSUIElement; setting it here too means `swift run` behaves
        // like the shipped app rather than bouncing in the Dock.
        application.setActivationPolicy(.accessory)

        // Never drawn under `.accessory`, and the panel's text fields cannot
        // cut, copy or paste without it.
        ApplicationMenu.install(in: application)

        application.run()
    }
}
