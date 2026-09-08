// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

/// The small-caps voice every section label inside a widget card speaks in —
/// Pinned, Recent, Downloads. One owner so the cards can't drift a size or a
/// shade apart; the insets stay with each caller, which is what differs.
struct SectionCaps: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }
}

extension View {
    /// Sets the shared section-label voice: uppercase is the caller's job.
    func sectionCaps() -> some View {
        modifier(SectionCaps())
    }
}

/// One section label inside a widget card: Pinned, Recent, Downloads.
///
/// The typography and the breath beneath it (`.padding(.bottom, Space.half)`)
/// are the whole component. The horizontal gutter is deliberately not owned
/// here: a label inside a padded `WidgetCard` and one over a full-bleed list
/// sit at different depths, so one constant would align neither — the caller
/// insets to its own rows.
///
/// Static with `WidgetSectionLabel("Recent")`; collapsible with
/// `WidgetSectionLabel("Pinned", isCollapsed: $isPinnedCollapsed)` — a binding
/// rather than a value-plus-callback pair, the way `Toggle` takes its state.
struct WidgetSectionLabel: View {
    private let title: String
    private var isCollapsed: Binding<Bool>?

    init(_ title: String) {
        self.title = title
        self.isCollapsed = nil
    }

    init(_ title: String, isCollapsed: Binding<Bool>) {
        self.title = title
        self.isCollapsed = isCollapsed
    }

    var body: some View {
        Group {
            if let isCollapsed {
                Button {
                    isCollapsed.wrappedValue.toggle()
                } label: {
                    HStack(spacing: Space.half) {
                        labelText
                        Image(systemName: isCollapsed.wrappedValue ? "chevron.right" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title) section")
                .accessibilityValue(isCollapsed.wrappedValue ? "Collapsed" : "Expanded")
                .accessibilityHint(isCollapsed.wrappedValue ? "Expands this section" : "Collapses this section")
            } else {
                labelText
            }
        }
        .padding(.bottom, Space.half)
    }

    private var labelText: some View {
        Text(title.uppercased())
            .sectionCaps()
    }
}

/// The breath between one section and the next: twelve points of air.
///
/// A bare `Color.clear` at the call site reads as a hack; named, it reads as
/// intent. It owns only its own height — any surrounding stack spacing
/// composes on top, so a `spacing: 0` list gets exactly twelve while Files'
/// `VStack(spacing: Space.half)` keeps the wider rhythm it already had.
struct WidgetSectionGap: View {
    var body: some View {
        Color.clear.frame(height: Space.oneHalf)
    }
}

/// The hairline under every row but the last: the list ends, it doesn't divide.
///
/// Inset to the row text rather than full-bleed, the way the rows themselves
/// are inset.
struct WidgetRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, Space.oneHalf)
    }
}
