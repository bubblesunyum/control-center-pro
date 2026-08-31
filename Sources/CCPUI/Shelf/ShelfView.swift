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
        VStack(alignment: .leading, spacing: 11) {
            header
            tiles
            if !shelf.items.isEmpty {
                bottomBar
            }
        }
        .padding(14)
        .frame(width: Self.panelWidth)
        .background(
            ZStack {
                VisualEffectViewRepresentable(material: .popover)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Color.cardFill
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.white.opacity(0.12),
                              lineWidth: isDropTargeted ? 2 : 1)
        )
        .overlay(alignment: .topLeading) {
            ShelfMoveHandle()
                .frame(width: Self.panelWidth - 96, height: 55)
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .onDrop(of: Self.dropTypes, isTargeted: $isDropTargeted) { providers in
            shelf.accept(providers: providers)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "tray.full")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !shelf.items.isEmpty {
                    Text("\(shelf.items.count)")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay(ShelfMoveHandle())

            pinButton
            closeButton
        }
    }

    private var pinButton: some View {
        Button { shelf.togglePin() } label: {
            Image(systemName: shelf.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(shelf.isPinned
                                  ? Color.accentColor.opacity(pinHovered ? 0.30 : 0.20)
                                  : Color.white.opacity(pinHovered ? 0.18 : 0.11))
                )
                .overlay(
                    Circle().strokeBorder(shelf.isPinned
                                          ? Color.accentColor.opacity(0.65)
                                          : Color.white.opacity(pinHovered ? 0.75 : 0.32),
                                          lineWidth: 1)
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
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(closeHovered ? 0.18 : 0.11)))
                .overlay(Circle().strokeBorder(Color.white.opacity(closeHovered ? 0.75 : 0.32), lineWidth: 1))
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
        HStack(spacing: 8) {
            Text("Drop files here — drag out to any app")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
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
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 42, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.red.opacity(clearHovered ? 0.20 : 0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.red.opacity(clearHovered ? 0.34 : 0.12), lineWidth: 0.8)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(clearHovered ? Color.red.opacity(0.82) : Color.secondary)
        .onHover { clearHovered = $0 }
        .help(shelf.selection.isEmpty ? "Clear all" : "Remove selected")
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
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .foregroundStyle(.secondary.opacity(0.4))
            .frame(height: Self.tileAreaHeight)
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 21))
                        .foregroundStyle(.secondary)
                    Text("Drop files, images, links or text here")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            )
            .overlay(ShelfMoveHandle())
    }
}

// MARK: - Move handle (AppKit drag)

private struct ShelfMoveHandle: NSViewRepresentable {
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

    private let columns = [GridItem(.fixed(78), spacing: 10),
                           GridItem(.fixed(78), spacing: 10),
                           GridItem(.fixed(78), spacing: 10)]
    private let tileSize = CGSize(width: 78, height: 88)

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(shelf.items) { item in
                    ShelfTile(item: item,
                              isSelected: shelf.selection.contains(item.id))
                        .frame(width: tileSize.width, height: tileSize.height)
                }
            }
            .padding(4)
        }
        .frame(height: ShelfView.tileAreaHeight)
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let isSelected: Bool
    @Environment(ShelfStore.self) private var shelf
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )

            VStack(spacing: 0) {
                iconWell
                Text(item.title)
                    .font(.system(size: 10))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(height: 24)
                    .padding(.horizontal, 3)
                    .padding(.top, 2)
            }
            .padding(.top, 6)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                    .padding(4)
            }

            if hover {
                Button { shelf.remove(item.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .background(Color.white.opacity(0.9).clipShape(Circle()))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(4)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hover = $0 }
        .onTapGesture {
            shelf.toggleSelection(item.id)
        }
        .onDrag {
            let writer = shelf.pasteboardWriter(for: item)
            let provider = NSItemProvider()
            // Prefer file URL when available, else string
            if let url = writer as? NSURL, url.isFileURL {
                provider.registerObject(url, visibility: .all)
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 64, height: 50)

            if let image = resolvedImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: isThumbnail ? 56 : 38, height: isThumbnail ? 42 : 34)
                    .clipShape(RoundedRectangle(cornerRadius: isThumbnail ? 4 : 0))
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: 22))
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
