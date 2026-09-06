// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// Thin root that hands the pill the shared store and its controller, the
/// way `ShelfPanelRoot` does for the shelf window: the pill looks shared
/// state up rather than holding a copy of it.
struct DropOverlayRoot: View {
    var controller: DropOverlayController

    var body: some View {
        DropOverlayPill()
            .environment(controller)
            .environment(ShelfStore.shared)
    }
}

/// What the drop-catcher offers: a glass capsule with a tray icon and the
/// shelf's count that ticks green the moment a drop lands. Same drop types as
/// the shelf itself (`ShelfStore.dropTypes`) and the same store entry point —
/// the pill is a target, not a second shelf.
struct DropOverlayPill: View {
    @Environment(DropOverlayController.self) private var controller
    @Environment(ShelfStore.self) private var store
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: Space.half) {
            Image(systemName: controller.justCaught ? "checkmark" : "tray.fill")
                .foregroundStyle(controller.justCaught ? Color.success : Color.primary)
            Text("\(store.itemCount)")
                .contentTransition(.numericText())
        }
        .padding(.horizontal, Space.two)
        .padding(.vertical, Space.one)
        // Card radius in the legacy fallback, which clips by points: the live
        // path draws the true capsule, and at this size the two agree.
        .background { GlassFill(Capsule(), cornerRadius: Radius.card) }
        .clipShape(Capsule())
        .overlay {
            Capsule().strokeBorder(
                isTargeted ? Color.accentColor : Color.cardStroke,
                lineWidth: isTargeted ? 2 : Stroke.hairline
            )
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drop files into shelf")
        .accessibilityValue(controller.justCaught ? "Added" : "\(store.itemCount) items")
        .onDrop(of: ShelfStore.dropTypes, isTargeted: $isTargeted) { providers in
            guard store.accept(providers: providers) else { return false }
            controller.didAcceptDrop()
            return true
        }
    }
}
