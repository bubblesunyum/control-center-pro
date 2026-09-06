// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

/// The shared language of the popover menus — the Files overflow first, the
/// Notes conflicts next: small-caps section labels, icon-led rows in a fixed
/// column, one hover fill. One rendering so the menus read as one family;
/// callers choose only rows.
///
/// psymail's `MenuRow` is not exported by `PsymailKit`, so this is CCP's own
/// in that shape, drawn with CCP's tokens.
struct PopoverMenuSectionLabel: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
            .padding(.horizontal, Space.one)
            .padding(.bottom, Space.quarter)
    }
}

/// One row in a popover menu: a leading symbol in a fixed column and a title,
/// with the row's hover fill.
struct PopoverMenuRow: View {
    private let systemImage: String
    private let title: String
    private var isDestructive = false
    private let action: () -> Void

    init(systemImage: String, title: String, isDestructive: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.title = title
        self.isDestructive = isDestructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.one) {
                Image(systemName: systemImage)
                    .fontWeight(.medium)
                    .frame(width: Layout.rowActionSize)
                Text(title)
                    // One line always: a long note name wraps to two and breaks
                    // the row rhythm — short fixed verbs never stressed this.
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Space.one)
            }
            .font(.caption)
            .foregroundStyle(isDestructive ? Color.red : Color.primary)
            .padding(.horizontal, Space.one)
            .padding(.vertical, Space.half)
            .frame(maxWidth: .infinity, minHeight: Layout.shelfMenuRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PopoverMenuRowStyle())
        .accessibilityLabel(title)
    }
}

struct PopoverMenuRowStyle: ButtonStyle {
    var isSelected = false
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                isSelected
                    ? Color.controlFill
                    : (hovered || configuration.isPressed ? Color.menuRowHover : Color.clear),
                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            )
            .onHover { hovered = $0 }
    }
}
