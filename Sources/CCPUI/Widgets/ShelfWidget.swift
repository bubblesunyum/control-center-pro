// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI
import UniformTypeIdentifiers

/// Dashboard card that launches the floating shelf.
///
/// The shelf itself is not a lane widget that lives inside the panel's glass —
/// it is a separate `NSPanel` that floats over the desktop so files can be
/// dragged into and out of any app. This card is the panel's affordance inside
/// CCP: it shows the count, offers to open the shelf at the mouse, and
/// surfaces the same Clear action the floating window's own bottom bar does.
@MainActor
public final class ShelfWidget: CCPWidget {
    public static let descriptor = WidgetDescriptor(
        id: "shelf",
        title: "Shelf",
        symbolName: "tray.full",
        size: .regular
    )

    public init() {}

    public func makeView() -> some View {
        ShelfWidgetContent()
            .environment(ShelfStore.shared)
    }
}

private struct ShelfWidgetContent: View {
    @Environment(ShelfStore.self) private var store
    @State private var window = ShelfWindowController.shared

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Space.one) {
                header
                if store.items.isEmpty {
                    emptyState
                } else {
                    preview
                    actions
                }
            }
            .padding(Space.oneHalf)
        }
        .onDrop(of: [.fileURL, .image, .url, .plainText], isTargeted: nil) { providers in
            store.accept(providers: providers)
        }
    }

    private var header: some View {
        HStack(spacing: Space.half) {
            Image(systemName: "tray.full")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Shelf")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if !store.items.isEmpty {
                Text("\(store.items.count)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, Space.half + Space.quarter).padding(.vertical, Space.quarter / 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                    .accessibilityLabel("\(store.items.count) items on shelf")
            }
            Spacer(minLength: 0)
            Button {
                window.toggle()
            } label: {
                Image(systemName: window.isVisible ? "xmark" : "arrow.up.forward.app")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.controlFill))
                    .overlay(Circle().strokeBorder(Color.cardStroke, lineWidth: Stroke.hairline))
            }
            .buttonStyle(.plain)
            .help(window.isVisible ? "Hide shelf" : "Open shelf")
            .accessibilityLabel(window.isVisible ? "Hide shelf" : "Open shelf")
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.half) {
            Image(systemName: "tray")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("Shelf is empty")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Drop files here or open the floating shelf to collect items.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Space.one)
        .background(Color.controlFill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var preview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.half) {
                ForEach(store.items.prefix(6)) { item in
                    ShelfWidgetChip(item: item)
                }
                if store.items.count > 6 {
                    Text("+\(store.items.count - 6)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Space.half)
                }
            }
        }
        .contentMargins(.horizontal, Space.one, for: .scrollContent)
        .contentMargins(.vertical, Space.one, for: .scrollContent)
        .background(Color.controlFill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private var actions: some View {
        HStack {
            Spacer(minLength: 0)
            Button(store.selection.isEmpty ? "Clear" : "Remove Selected", role: .destructive) {
                if store.selection.isEmpty {
                    store.clear()
                } else {
                    store.removeSelected()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(store.selection.isEmpty ? "Clear shelf" : "Remove selected from shelf")
        }
    }
}

private struct ShelfWidgetChip: View {
    let item: ShelfItem

    var body: some View {
        VStack(spacing: Space.quarter) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 28)
                .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous))
            Text(item.title)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 44)
        }
        .padding(.horizontal, Space.quarter)
        .help(item.title)
        .accessibilityLabel(item.title)
    }

    private var symbol: String {
        switch item.kind {
        case .file: return "doc.fill"
        case .text: return "note.text"
        case .link: return "link"
        case .image: return "photo"
        }
    }
}


