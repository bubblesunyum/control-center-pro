// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// Everything this build offers, and a way to put one on the panel.
///
/// Built from the arrangement's own catalogue, so registering a widget is the
/// whole of adding it to the gallery — there is no second list to keep in step,
/// which is the same promise the registry makes to the lanes.
struct WidgetGallery: View {
    let arrangement: PanelArrangement
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Widgets")
                .font(.headline)
                .padding(.horizontal, Space.oneHalf)
                .padding(.vertical, Space.one)

            Divider()

            ForEach(arrangement.gallery) { entry in
                GalleryRow(entry: entry) {
                    withAnimation(.snappy) { arrangement.add(entry.id) }
                    onAdd()
                }
            }
        }
        .frame(width: Layout.laneWidth)
        .padding(.bottom, Space.half)
    }
}

private struct GalleryRow: View {
    let entry: GalleryEntry
    let add: () -> Void

    var body: some View {
        Button(action: add) {
            HStack(spacing: Space.one) {
                Image(systemName: entry.descriptor.symbolName)
                    .frame(width: Space.two)

                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.descriptor.title)
                    // Every permission, in a settled order: they arrive as a
                    // Set, so showing "the first one" would name a different
                    // one run to run once a widget declares two.
                    ForEach(entry.descriptor.requirements, id: \.self) { requirement in
                        Text(requirement)
                            .font(.caption)
                            .foregroundStyle(Color.labelMuted)
                    }
                }

                Spacer(minLength: Space.one)

                if entry.isPlaced {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.labelMuted)
                }
            }
            .contentShape(.rect)
            .padding(.horizontal, Space.oneHalf)
            .padding(.vertical, Space.one)
        }
        .buttonStyle(.plain)
        .disabled(entry.isPlaced)
        .accessibilityLabel(entry.isPlaced ? "\(entry.descriptor.title), already on the panel" : "Add \(entry.descriptor.title)")
    }
}

private extension WidgetDescriptor {
    /// What the widget will have to ask the user for, in a stable order.
    /// Whether any of it has been granted is not known here — see ccp-23w.
    var requirements: [String] {
        permissions.map(\.requirement).sorted()
    }
}

private extension WidgetPermission {
    var requirement: String {
        switch self {
        case .audioCapture: "Needs audio recording access"
        case .accessibility: "Needs accessibility access"
        }
    }
}
