// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import SwiftUI
import QuickLookThumbnailing
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
    @State private var keepOpenHovered = false
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
                Image(systemName: "folder.fill")
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

            keepOpenButton
            closeButton
        }
    }

    /// Keeps the window up when focus leaves it — not to be confused with
    /// pinning an item, which is on the tile itself.
    private var keepOpenButton: some View {
        Button { shelf.toggleKeepsWindowOpen() } label: {
            Image(systemName: shelf.keepsWindowOpen ? "macwindow.on.rectangle" : "macwindow")
                .font(.caption.weight(.semibold))
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(shelf.keepsWindowOpen
                                  ? Color.accentColor.opacity(keepOpenHovered ? 0.30 : 0.20)
                                  : Color.controlFill)
                )
                .overlay(
                    Circle().strokeBorder(shelf.keepsWindowOpen
                                          ? Color.accentColor.opacity(0.65)
                                          : Color.cardStroke,
                                          lineWidth: Stroke.hairline)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(shelf.keepsWindowOpen ? Color.accentColor : Color.secondary)
        .onHover { keepOpenHovered = $0 }
        .help(shelf.keepsWindowOpen ? "Let Files close on its own" : "Keep Files open")
        .accessibilityLabel(shelf.keepsWindowOpen ? "Stop keeping Files open" : "Keep Files open")
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
        .accessibilityLabel("Close Files")
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
        .disabled(shelf.selection.isEmpty && !shelf.hasUnpinnedItems)
        .help(shelf.selection.isEmpty ? "Clear unpinned" : "Remove selected")
        .accessibilityLabel(shelf.selection.isEmpty ? "Clear unpinned" : "Remove selected")
        .accessibilityHint(shelf.selection.isEmpty ? "Removes every unpinned item from Files" : "Removes selected items")
    }

    private var title: String {
        shelf.selection.isEmpty ? "Files" : "\(shelf.selection.count) selected"
    }

    // MARK: - Tiles

    @ViewBuilder
    private var tiles: some View {
        if shelf.items.isEmpty {
            emptyState
        } else {
            ShelfList()
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

// MARK: - File list (replaces the tile grid)

private struct ShelfList: View {
    @Environment(ShelfStore.self) private var shelf

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: Space.half) {
                ForEach(shelf.items) { item in
                    ShelfRow(item: item)
                }
            }
            .padding(Space.half)
        }
        .frame(height: ShelfView.tileAreaHeight)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

private struct ShelfRow: View {
    let item: ShelfItem
    @Environment(ShelfStore.self) private var shelf
    @State private var hover = false

    private var isSelected: Bool { shelf.selection.contains(item.id) }

    var body: some View {
        HStack(spacing: Space.one) {
            iconPreview
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: Space.half)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            } else if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
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
                .accessibilityLabel("Remove \(item.title)")
            }
        }
        .padding(.vertical, Space.half)
        .padding(.horizontal, Space.quarter)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { shelf.toggleSelection(item.id) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityValue(rowValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction { shelf.toggleSelection(item.id) }
        .accessibilityAction(named: item.isPinned ? "Unpin" : "Pin") { shelf.togglePin(item.id) }
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: isSelected ? 1 : 0)
        )
        .onDrag {
            let writer = shelf.pasteboardWriter(for: item)
            let provider = NSItemProvider()
            if let url = writer as? NSURL, url.isFileURL {
                provider.registerObject(url, visibility: .all)
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
            Button(item.isPinned ? "Unpin" : "Pin") { shelf.togglePin(item.id) }
            Button("Remove", role: .destructive) { shelf.remove(item.id) }
        }
        .help(item.title)
    }

    @ViewBuilder
    private var iconPreview: some View {
        let previewSize = CGSize(width: 42, height: 56)
        Group {
            if let preview = previewImage {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: previewSize.width, height: previewSize.height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if item.kind == .file, let path = item.filePath {
                FileThumbnailView(
                    url: URL(fileURLWithPath: path),
                    size: previewSize,
                    fallbackIcon: fileTypeIcon,
                    symbolName: symbolName
                )
            } else if let icon = fileTypeIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
                    .frame(width: previewSize.width, height: previewSize.height)
            } else {
                Image(systemName: symbolName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: previewSize.width, height: previewSize.height)
            }
        }
        .frame(width: previewSize.width, height: previewSize.height)
    }

    private var subtitle: String {
        switch item.kind {
        case .file:
            if let path = item.filePath {
                let ext = (path as NSString).pathExtension.lowercased()
                if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                    return type.localizedDescription ?? ext.uppercased()
                }
                if !ext.isEmpty { return ext.uppercased() }
                return "File"
            }
            return "File"
        case .image:
            if let name = item.imageFileName {
                let ext = (name as NSString).pathExtension.uppercased()
                return ext.isEmpty ? "Image" : "\(ext) Image"
            }
            return "Image"
        case .link:
            if let s = item.urlString, let url = URL(string: s) {
                return url.host ?? "Link"
            }
            return "Link"
        case .text:
            return "Text"
        }
    }

    private var rowValue: String {
        [isSelected ? "Selected" : nil, item.isPinned ? "Pinned" : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private var symbolName: String {
        switch item.kind {
        case .file:
            if let path = item.filePath {
                let ext = (path as NSString).pathExtension.lowercased()
                if let type = UTType(filenameExtension: ext) {
                    if type.conforms(to: .image) { return "photo.fill" }
                    if type.conforms(to: .movie) { return "film.fill" }
                    if type.conforms(to: .audio) { return "music.note" }
                    if type.conforms(to: .pdf) { return "doc.richtext.fill" }
                    if type.conforms(to: .zip) || ext == "zip" { return "doc.zipper" }
                }
            }
            return "doc.fill"
        case .text: return "note.text"
        case .link: return "link"
        case .image: return "photo"
        }
    }

    private var previewImage: NSImage? {
        if item.kind == .image, let name = item.imageFileName {
            let url = ShelfStore.storeDirectory.appendingPathComponent(name)
            if let img = NSImage(contentsOf: url) { return img }
        }
        if item.kind == .file, let path = item.filePath {
            let url = URL(fileURLWithPath: path)
            if let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image) {
                if let img = NSImage(contentsOf: url) { return img }
            }
        }
        return nil
    }

    private var fileTypeIcon: NSImage? {
        guard item.kind == .file, let path = item.filePath else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }
}

private struct FileThumbnailView: View {
    let url: URL
    let size: CGSize
    let fallbackIcon: NSImage?
    let symbolName: String
    @State private var thumb: NSImage?
    @State private var attempted = false

    var body: some View {
        Group {
            if let t = thumb {
                Image(nsImage: t)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if attempted {
                Group {
                    if let icon = fallbackIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: symbolName)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: size.width, height: size.height)
            } else {
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .onAppear { generate() }
            }
        }
        .task { generate() }
    }

    private func generate() {
        guard !attempted, thumb == nil else { return }
        // Use QuickLook to generate a real thumbnail (PDFs, docs, etc.) instead of a generic file icon.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, error in
            DispatchQueue.main.async {
                if let rep {
                    self.thumb = rep.nsImage
                    self.attempted = true
                } else {
                    // No thumbnail available — fall back to the workspace icon.
                    self.attempted = true
                }
            }
        }
    }
}

