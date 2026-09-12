// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

/// The toolbar's icon cell: caption symbol in a row-action frame, wearing the
/// shared hover chip. The frame and font stay here — only the hover behaviour
/// lives in the modifier. Worn by the note's bottom toolbar and the format
/// rail alike, so the two never disagree about what a pressable looks like.
struct NoteToolbarIcon: View {
    let symbol: String
    let tint: Color?

    // Explicit: a `let` with a default drops out of the memberwise init
    // beside a property wrapper, so the default lives here instead.
    init(symbol: String, tint: Color? = nil) {
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.caption)
            .frame(width: Layout.rowActionSize, height: Layout.rowActionSize)
            .contentShape(Rectangle())
            .hoverChip(tint: tint)
    }
}

/// One icon button with a hover chip, help, and label. The frame and font
/// live on the icon, the behaviour on the shared modifier.
struct NoteToolbarButton: View {
    private let symbol: String
    private let label: String
    private let tint: Color?
    private let action: () -> Void

    init(_ symbol: String, label: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            NoteToolbarIcon(symbol: symbol, tint: tint)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
