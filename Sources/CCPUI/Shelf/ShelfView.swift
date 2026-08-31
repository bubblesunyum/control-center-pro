// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import SwiftUI
import UniformTypeIdentifiers

/// Floating shelf panel contents — header, tiles, and bottom bar.
///
/// This is a direct adaptation of `Sources/Vorssaint/UI/Shelf/ShelfView.swift`:
/// same 304pt width, 188pt tile area, header with move handle + count badge +
/// pin/close, dashed empty state, `isDropTargeted` stroke. The brand watermark
/// and `HUDBackdrop` are replaced by CCP's glass (`VisualEffectViewRepresentable`
/// + `Color.cardFill`), and `L10n` strings become literals — those are the only
/// intentional deltas. The layout reads as the same shelf, not a reimagining.
struct ShelfView: View {
    var onDismiss: (() -> Void)? = nil

    @Environment(ShelfStore.self) private var shelf
    @State private var isDropTargeted = false
    @State private var closeHovered = false
    @State private var pinHovered = false
    @State private var clearHovered = false

    private static let dropTypes: [UTType] = [.fileURL, .image, .url, .plainText, .text]
    static let panelWidth: CGFloat = 304
    static let tileAreaHeight: CGFloat = 188

    var body: some View {
        VStack(alignment: .leading, spacing: Space.oneHalf) {
            header
            tiles
            if !shelf.items.isEmpty {
                bottomBar
            }
        }
        .padding(Space.oneHalf)
        .frame(width: Self.panelWidth)
        .background(
            ZStack {
                VisualEffectViewRepresentable(material: .popover)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                Color.cardFill
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.cardStroke,
                              lineWidth: isDropTargeted ? 2 : Stroke.hairline)
        )
        .overlay(alignment: .topLeading) {
            ShelfPanelMoveViewRepresentable()
                .frame(width: Self.panelWidth - 96, height: 55)
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .onDrop(of: Self.dropTypes, isTargeted: $isDropTargeted) { providers in
            shelf.accept(providers: providers)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.half) {
            HStack(spacing: Space.half) {
                Image(systemName: "tray.full")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !shelf.items.isEmpty {
                    Text("\(shelf.items.count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, Space.half + Space.quarter).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay(ShelfPanelMoveViewRepresentable())

            pinButton
            closeButton
        }
    }

    private var pinButton: some View {
        Button { shelf.togglePin() } label: {
            Image(systemName: shelf.isPinned ? "pin.fill" : "pin")
                .font(.caption.weight(.semibold))
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(shelf.isPinned
                                  ? Color.accentColor.opacity(pinHovered ? 0.30 : 0.20)
                                  : Color.controlFill)
                )
                .overlay(
                    Circle().strokeBorder(shelf.isPinned
                                          ? Color.accentColor.opacity(0.65)
                                          : Color.cardStroke,
                                          lineWidth: Stroke.hairline)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(shelf.isPinned ? Color.accentColor : Color.secondary)
        .onHover { pinHovered = $0 }
        .help(shelf.isPinned ? "Unpin" : "Pin")
        .accessibilityLabel(shelf.isPinned ? "Unpin shelf" : "Pin shelf")
    }

    private var closeButton: some View {
        Button { (onDismiss ?? { ShelfWindowController.shared.hide() })() } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.controlFill))
                .overlay(Circle().strokeBorder(Color.cardStroke, lineWidth: Stroke.hairline))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { closeHovered = $0 }
        .help("Close")
        .accessibilityLabel("Close shelf")
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: Space.one) {
            Text("Drop files here — drag out to any app")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: Space.half)
            clearButton
        }
        .frame(minHeight: 30)
    }

    private var clearButton: some View {
        Button {
            if shelf.selection.isEmpty {
                shelf.clear()
            } else {
                shelf.removeSelected()
            }
        } label: {
            Image(systemName: shelf.selection.isEmpty ? "trash" : "trash.fill")
                .font(.caption.weight(.semibold))
                .frame(width: 42, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Color.red.opacity(clearHovered ? 0.20 : 0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Color.red.opacity(clearHovered ? 0.34 : 0.12), lineWidth: Stroke.hairline)
                )
                .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(clearHovered ? Color.red.opacity(0.82) : Color.secondary)
        .onHover { clearHovered = $0 }
        .help(shelf.selection.isEmpty ? "Clear all" : "Remove selected")
        .accessibilityLabel(shelf.selection.isEmpty ? "Clear all" : "Remove selected")
        .accessibilityHint(shelf.selection.isEmpty ? "Removes all items from the shelf" : "Removes selected items")
    }

    private var title: String {
        shelf.selection.isEmpty ? "Shelf" : "\(shelf.selection.count) selected"
    }

    // MARK: - Tiles

    @ViewBuilder
    private var tiles: some View {
        if shelf.items.isEmpty {
            emptyState
        } else {
            ShelfTilesGrid()
                .frame(height: Self.tileAreaHeight)
                .environment(shelf)
        }
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: Stroke.hairline, dash: [6, 5]))
            .foregroundStyle(.secondary.opacity(0.4))
            .frame(height: Self.tileAreaHeight)
            .overlay(
                VStack(spacing: Space.half) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Drop files, images, links or text here")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            )
            .overlay(ShelfPanelMoveViewRepresentable())
    }
}

// MARK: - Move handle (AppKit drag)

private struct ShelfPanelMoveViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> ShelfPanelMoveView {
        ShelfPanelMoveView()
    }
    func updateNSView(_ nsView: ShelfPanelMoveView, context: Context) {}
}

final class ShelfPanelMoveView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - Tiles grid (SwiftUI replacement for AppKit ShelfTilesView)

private struct ShelfTilesGrid: View {
    @Environment(ShelfStore.self) private var shelf

    private let columns = [GridItem(.fixed(78), spacing: Space.one),
                           GridItem(.fixed(78), spacing: Space.one),
                           GridItem(.fixed(78), spacing: Space.one)]
    private let tileSize = CGSize(width: 78, height: 88)

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVGrid(columns: columns, spacing: Space.one) {
                ForEach(shelf.items) { item in
                    ShelfTile(item: item)
                        .frame(width: tileSize.width, height: tileSize.height)
                }
            }
            .padding(Space.half)
        }
        .frame(height: ShelfView.tileAreaHeight)
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    @Environment(ShelfStore.self) private var shelf
    @State private var hover = false

    private var isSelected: Bool { shelf.selection.contains(item.id) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: isSelected ? 2 : Stroke.hairline)
                )

            VStack(spacing: 0) {
                iconWell
                Text(item.title)
                    .font(.caption2)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 24)
                    .padding(.horizontal, Space.quarter)
                    .padding(.top, Space.quarter)
            }
            .padding(.top, Space.half)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .padding(Space.half)
                    .accessibilityHidden(true)
            }

            if hover {
                Button { shelf.remove(item.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .background(Color.white.opacity(0.9).clipShape(Circle()))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(Space.half)
                .accessibilityLabel("Remove \(item.title)")
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .onHover { hover = $0 }
        .onTapGesture {
            shelf.toggleSelection(item.id)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction { shelf.toggleSelection(item.id) }
        .onDrag {
            let writer = shelf.pasteboardWriter(for: item)
            let provider = NSItemProvider()
            if let url = writer as? NSURL, url.isFileURL {
                provider.registerObject(url, visibility: .all)
                // Fallback for plain-text consumers
                if let str = item.text ?? item.urlString {
                    provider.registerObject(str as NSString, visibility: .all)
                }
            } else if let str = writer as? NSString {
                provider.registerObject(str, visibility: .all)
            } else if let url = writer as? NSURL {
                provider.registerObject(url, visibility: .all)
            }
            return provider
        }
        .contextMenu {
            if item.kind == .file, let path = item.filePath {
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Divider()
            } else if item.kind == .link, let s = item.urlString, let url = URL(string: s) {
                Button("Open") { NSWorkspace.shared.open(url) }
                Divider()
            } else if item.kind == .text, let t = item.text {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string) }
                Divider()
            }
            Button("Remove", role: .destructive) { shelf.remove(item.id) }
        }
        .help(item.title)
    }

    @ViewBuilder
    private var iconWell: some View {
        let isThumbnail = item.kind == .image && item.imageFileName != nil
        ZStack {
            RoundedRectangle(cornerRadius: Radius.control - 2, style: .continuous)
                .fill(Color.controlFill)
                .frame(width: 64, height: 50)

            if let image = resolvedImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: isThumbnail ? 56 : 38, height: isThumbnail ? 42 : 34)
                    .clipShape(RoundedRectangle(cornerRadius: isThumbnail ? 4 : 0))
            } else {
                Image(systemName: symbolName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var symbolName: String {
        switch item.kind {
        case .file: return "doc.fill"
        case .text: return "note.text"
        case .link: return "link"
        case .image: return "photo"
        }
    }

    private var resolvedImage: NSImage? {
        switch item.kind {
        case .file:
            if let path = item.filePath {
                return NSWorkspace.shared.icon(forFile: path)
            }
            return nil
        case .image:
            if let name = item.imageFileName {
                let url = ShelfStore.storeDirectory.appendingPathComponent(name)
                if let img = NSImage(contentsOf: url) { return img }
            }
            return NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        case .link, .text:
            return nil
        }
    }
}
