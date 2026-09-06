// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

/// A content drag that yields while the panel is editing, where drags
/// reorder widgets instead. One capability for every row that drags out —
/// shelf tiles, downloads, clipboard history — so the gate can't drift
/// between call sites (ccp-xc8).
struct DragOutModifier: ViewModifier {
    let provider: () -> NSItemProvider
    @Environment(\.isPanelEditing) private var isPanelEditing

    func body(content: Content) -> some View {
        if isPanelEditing {
            content
        } else {
            content.onDrag(provider)
        }
    }
}

extension View {
    /// Drag `provider`'s content out of the panel. Disabled while editing.
    func dragOut(_ provider: @escaping () -> NSItemProvider) -> some View {
        modifier(DragOutModifier(provider: provider))
    }
}
