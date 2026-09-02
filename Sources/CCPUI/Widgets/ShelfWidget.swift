// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Dashboard card that launches the floating Files window.
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
        title: "Files",
        symbolName: "folder.fill",
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
            HStack(spacing: Space.half) {
                if !store.items.isEmpty {
                    clearButtonHeader
                }
                HeaderIconButton(
                    systemImage: window.isVisible ? "xmark" : "arrow.up.forward.app",
                    label: window.isVisible ? "Hide Files" : "Open Files"
                ) {
                    window.toggle()
                }
            }
        } content: {
            // Nothing below the header until something is on the shelf: an
            // empty box explaining where to drop is a second, larger empty
            // state next to the one the floating shelf already draws.
            if !store.items.isEmpty {
                preview
                    .transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.2), value: store.items.isEmpty)
        .onDrop(of: [.fileURL, .image, .url, .plainText], isTargeted: nil) { providers in
            store.accept(providers: providers)
        }
    }

    private var clearButtonHeader: some View {
        Button {
            if store.selection.isEmpty {
                store.clear()
            } else {
                store.removeSelected()
            }
        } label: {
            Image(systemName: store.selection.isEmpty ? "trash" : "trash.fill")
                .font(.caption.weight(.semibold))
                .frame(width: Layout.headerAccessorySize, height: Layout.headerAccessorySize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(store.selection.isEmpty && !store.hasUnpinnedItems)
        .help(store.selection.isEmpty ? "Clear unpinned" : "Remove selected")
        .accessibilityLabel(store.selection.isEmpty ? "Clear unpinned items" : "Remove selected from Files")
        .accessibilityHint(store.selection.isEmpty ? "Removes every unpinned item from Files" : "Removes selected items")
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: Space.half) {
            ForEach(store.items.prefix(6)) { item in
                WidgetFileRow(item: item)
                    .contextMenu {
                        Button(item.isPinned ? "Unpin" : "Pin") { store.togglePin(item.id) }
                        Button("Remove", role: .destructive) { store.remove(item.id) }
                    }
            }
            if store.items.count > 6 {
                Text("+\(store.items.count - 6) more")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.half)
            }
        }
        .padding(.top, Space.half)
    }
}

private struct WidgetFileRow: View {
    let item: ShelfItem
    @Environment(ShelfStore.self) private var store
    @Environment(\.isPanelEditing) private var isPanelEditing
    @State private var isHovered = false

    private var isSelected: Bool { store.selection.contains(item.id) }

    private var rowValue: String {
        [isSelected ? "Selected" : nil, item.isPinned ? "Pinned" : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

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
            if isHovered {
                Button { store.remove(item.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .background(Color.white.opacity(0.9).clipShape(Circle()))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(item.title)")
            }
        }
        .padding(.vertical, Space.quarter)
        .padding(.horizontal, Space.quarter)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
                .fill(isSelected ? Color.pinnedFill : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
                .strokeBorder(isSelected ? Color.pinnedStroke : Color.clear, lineWidth: isSelected ? 1 : 0)
        )
        .onHover { isHovered = $0 }
        .onTapGesture {
            if !isPanelEditing {
                store.toggleSelection(item.id)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityValue(rowValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction { store.toggleSelection(item.id) }
        .accessibilityAction(named: item.isPinned ? "Unpin" : "Pin") { store.togglePin(item.id) }
        .help(item.title)
        .modifier(WidgetFileRowDragModifier(item: item))
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
                    symbolName: symbol
                )
            } else if let icon = fileTypeIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
                    .frame(width: previewSize.width, height: previewSize.height)
            } else {
                Image(systemName: symbol)
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

    private var symbol: String {
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

private struct WidgetFileRowDragModifier: ViewModifier {
    let item: ShelfItem
    @Environment(ShelfStore.self) private var store
    @Environment(\.isPanelEditing) private var isPanelEditing

    func body(content: Content) -> some View {
        if isPanelEditing {
            content
        } else {
            content
                .onDrag {
                    let provider = NSItemProvider()
                    // Prefer fileURLs so Finder receives a concrete file even for text/link
                    let urls = store.fileURLs(for: [item.id])
                    if let url = urls.first, FileManager.default.fileExists(atPath: url.path) {
                        provider.registerObject(url as NSURL, visibility: .all)
                        // Also vend a string/URL representation so drops into text fields work
                        if let text = item.text {
                            provider.registerObject(text as NSString, visibility: .all)
                        } else if let link = item.urlString {
                            provider.registerObject(link as NSString, visibility: .all)
                            if let u = URL(string: link) {
                                provider.registerObject(u as NSURL, visibility: .all)
                            }
                        }
                        provider.suggestedName = url.lastPathComponent
                        return provider
                    }
                    // Ghost or failed write: vend only non-file representations to avoid
                    // handing Finder a dead file URL.
                    let writer = store.pasteboardWriter(for: item)
                    if let url = writer as? NSURL {
                        if url.isFileURL {
                            guard let path = url.path, FileManager.default.fileExists(atPath: path) else {
                                let fallback = item.text ?? item.urlString ?? item.title
                                provider.registerObject(fallback as NSString, visibility: .all)
                                provider.suggestedName = item.title
                                return provider
                            }
                        }
                        provider.registerObject(url, visibility: .all)
                    } else if let str = writer as? NSString {
                        provider.registerObject(str, visibility: .all)
                    } else if let fallback = item.text ?? item.urlString {
                        provider.registerObject(fallback as NSString, visibility: .all)
                    }
                    provider.suggestedName = item.title
                    return provider
                }
        }
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
                            .frame(width: 24, height: 24)
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
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, error in
            DispatchQueue.main.async {
                if let rep {
                    self.thumb = rep.nsImage
                    self.attempted = true
                } else {
                    self.attempted = true
                }
            }
        }
    }
}

