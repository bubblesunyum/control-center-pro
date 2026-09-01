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
/// With nothing on the shelf it is just its header — an empty box explaining
/// where to drop things is the floating shelf's job, not a second one here.
@MainActor
public final class ShelfWidget: CCPWidget {
    public static let descriptor = WidgetDescriptor(
        id: "shelf",
        title: "Shelf",
        symbolName: "tray.full",
        // An empty shelf is a header and nothing else. The card grows to fit
        // its chips the moment something lands on it, so the declared size is
        // the floor for the empty case rather than a shape to fill.
        size: .compact
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
        WidgetCard(ShelfWidget.descriptor, count: store.items.isEmpty ? nil : store.items.count) {
            HeaderIconButton(
                systemImage: window.isVisible ? "xmark" : "arrow.up.forward.app",
                label: window.isVisible ? "Hide shelf" : "Open shelf"
            ) {
                window.toggle()
            }
        } content: {
            // Nothing below the header until something is on the shelf: an
            // empty box explaining where to drop is a second, larger empty
            // state next to the one the floating shelf already draws.
            if !store.items.isEmpty {
                VStack(alignment: .leading, spacing: Space.one) {
                    preview
                    actions
                }
                .transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.2), value: store.items.isEmpty)
        .onDrop(of: [.fileURL, .image, .url, .plainText], isTargeted: nil) { providers in
            store.accept(providers: providers)
        }
    }

    private var preview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.half) {
                ForEach(store.items.prefix(6)) { item in
                    ShelfWidgetChip(item: item)
                        .contextMenu {
                            Button(item.isPinned ? "Unpin" : "Pin") { store.togglePin(item.id) }
                            Button("Remove", role: .destructive) { store.remove(item.id) }
                        }
                }
                if store.items.count > 6 {
                    Text("+\(store.items.count - 6)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Space.half)
                }
            }
        }
        // No well behind the row: it would stretch to the lane's full width and
        // read as a half-empty trough on the way to six chips. Each chip
        // already carries its own tile.
        .contentMargins(.vertical, Space.half, for: .scrollContent)
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
            .disabled(store.selection.isEmpty && !store.hasUnpinnedItems)
            .accessibilityLabel(store.selection.isEmpty ? "Clear unpinned items" : "Remove selected from shelf")
        }
    }
}

private struct ShelfWidgetChip: View {
    let item: ShelfItem

    var body: some View {
        VStack(spacing: Space.quarter) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.isPinned ? Color.accentColor : .secondary)
                .frame(width: Layout.shelfChipIconWidth, height: Layout.shelfChipIconHeight)
                .background(item.isPinned ? Color.pinnedFill : Color.cardFill,
                            in: RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
                        .strokeBorder(item.isPinned ? Color.pinnedStroke : Color.clear, lineWidth: Stroke.hairline)
                )
            Text(item.title)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Layout.shelfChipWidth)
        }
        .padding(.horizontal, Space.quarter)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.isPinned ? "Pinned" : "")
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


