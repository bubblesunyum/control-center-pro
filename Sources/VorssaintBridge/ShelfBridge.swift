// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Public visibility for the shelf's drag-gesture policy. `ShelfService`
/// itself is excluded from the build, but its pure interaction helpers in
/// `ShelfSupport.swift` still compile — this is the one CCP reads, so an
/// upstream tweak to what counts as a content drag flows through on merge
/// instead of silently forking.
public enum BridgedShelfInteraction {
    public static func isContentDrag(
        baselineChangeCount: Int,
        changeCount: Int,
        beganInDock: Bool,
        hasDroppableContent: () -> Bool
    ) -> Bool {
        ShelfInteractionSupport.isContentDrag(
            baselineChangeCount: baselineChangeCount,
            changeCount: changeCount,
            beganInDock: beganInDock,
            hasDroppableContent: hasDroppableContent
        )
    }
}
