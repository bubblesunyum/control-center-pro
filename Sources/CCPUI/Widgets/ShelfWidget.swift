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
/// CCP: pinned and recent shelf items, the 9 latest downloads, and an overflow
/// menu with the same Open/Clear actions the floating window's own bottom bar
/// offers. With nothing anywhere — empty shelf, empty downloads — it is just
/// its header.
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

    private let hiddenFilesAdapter: QuickTogglesAdapter

    public init() {
        self.hiddenFilesAdapter = QuickTogglesAdapter()
    }

    /// Test seam: a Files widget backed by a fake hidden-files source.
    init(source: QuickTogglesSource) {
        self.hiddenFilesAdapter = QuickTogglesAdapter(source: source)
    }

    public func makeView() -> some View {
        ShelfWidgetContent(hiddenFiles: hiddenFilesAdapter)
            .environment(ShelfStore.shared)
    }

    public func activate() { hiddenFilesAdapter.activate() }
    public func deactivate() { hiddenFilesAdapter.deactivate() }
}

private struct ShelfWidgetContent: View {
    /// Rows shown per shelf section before the "+N more" line takes over.
    /// The panel never scrolls, so an uncapped section would push rows the
    /// clamp then cuts off with no way to reach them.
    private static let maxSectionRows = 6

    @Environment(ShelfStore.self) private var store
    @State private var window = ShelfWindowController.shared
    @Bindable var hiddenFiles: QuickTogglesAdapter
    @State private var isMenuPresented = false
    @State private var isPinnedCollapsed = false
    @State private var isDownloadsCollapsed = false
    @State private var downloads = RecentDownloadsStore()

    private var pinned: [ShelfItem] { store.items.filter(\.isPinned) }
    private var unpinned: [ShelfItem] { store.items.filter { !$0.isPinned } }

    var body: some View {
        WidgetCard(ShelfWidget.descriptor) {
            HeaderIconButton(systemImage: "ellipsis", label: "Files actions") {
                isMenuPresented = true
            }
            .popover(isPresented: $isMenuPresented, arrowEdge: .top) {
                ShelfOverflowMenu(
                    window: window,
                    hiddenFiles: hiddenFiles,
                    dismiss: { isMenuPresented = false }
                )
                .environment(store)
            }
        } content: {
            // Nothing below the header until something is anywhere: an empty
            // box explaining where to drop is the floating shelf's job, not a
            // second one here.
            if !store.items.isEmpty || !downloads.files.isEmpty {
                VStack(alignment: .leading, spacing: Space.half) {
                    if !pinned.isEmpty {
                        shelfSectionHeader(title: "Pinned", isCollapsed: isPinnedCollapsed) {
                            isPinnedCollapsed.toggle()
                        }
                        if !isPinnedCollapsed {
                            ForEach(pinned.prefix(Self.maxSectionRows)) { item in
                                shelfRow(for: item)
                            }
                            moreLabel(remaining: pinned.count - Self.maxSectionRows)
                        }
                    }
                    if !unpinned.isEmpty {
                        if !pinned.isEmpty, !isPinnedCollapsed {
                            Divider().padding(.vertical, Space.quarter)
                        }
                        ForEach(unpinned.prefix(Self.maxSectionRows)) { item in
                            shelfRow(for: item)
                        }
                        moreLabel(remaining: unpinned.count - Self.maxSectionRows)
                    }
                    if !downloads.files.isEmpty {
                        if !store.items.isEmpty {
                            Divider().padding(.vertical, Space.quarter)
                        }
                        shelfSectionHeader(title: "Recent Downloads", isCollapsed: isDownloadsCollapsed) {
                            isDownloadsCollapsed.toggle()
                        }
                        if !isDownloadsCollapsed {
                            ForEach(downloads.files) { file in
                                RecentDownloadRow(file: file)
                            }
                        }
                    }
                }
                .padding(.top, Space.half)
                .transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.2), value: store.items.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: hiddenFiles.hiddenFilesShown)
        .animation(.easeInOut(duration: 0.2), value: hiddenFiles.isToggling)
        .task { await downloads.reload() }
        .onDrop(of: [.fileURL, .image, .url, .plainText], isTargeted: nil) { providers in
            store.accept(providers: providers)
        }
    }

    private func shelfRow(for item: ShelfItem) -> some View {
        WidgetFileRow(item: item)
            .contextMenu {
                Button(item.isPinned ? "Unpin" : "Pin") { store.togglePin(item.id) }
                Button("Remove", role: .destructive) { store.remove(item.id) }
            }
    }

    @ViewBuilder
    private func moreLabel(remaining: Int) -> some View {
        if remaining > 0 {
            Text("+\(remaining) more")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.half)
        }
    }

    private func shelfSectionHeader(
        title: String,
        isCollapsed: Bool,
        toggle: @escaping () -> Void
    ) -> some View {
        Button(action: toggle) {
            HStack(spacing: Space.half) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.half)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) section")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(isCollapsed ? "Expands this section" : "Collapses this section")
    }
}

/// The Files card's overflow menu: the header's three actions behind one
/// three-dot button, in the language of an iOS context menu — section labels,
/// icon-led rows, a toggle row under TOOLS.
///
/// psymail's own glass menu (`Menu`/`MenuRow` in psymail-mini's app target) is
/// not part of `PsymailKit`, so this is CCP's own rendering in that language
/// rather than a reuse: same fixed icon column, same hover fill, same section
/// headers, drawn with CCP's tokens.
private struct ShelfOverflowMenu: View {
    @Environment(ShelfStore.self) private var store
    let window: ShelfWindowController
    @Bindable var hiddenFiles: QuickTogglesAdapter
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Actions".uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
                .padding(.horizontal, Space.one)
                .padding(.top, Space.half)
                .padding(.bottom, Space.quarter)
            ShelfMenuRow(
                systemImage: window.isVisible ? "xmark" : "arrow.up.forward.app",
                title: window.isVisible ? "Hide shelf" : "Open shelf"
            ) {
                window.toggle()
                dismiss()
            }
            .accessibilityHint(window.isVisible ? "Hides the floating Files window" : "Shows the floating Files window")
            if store.selection.isEmpty {
                ShelfMenuRow(systemImage: "trash", title: "Clear all", isDestructive: true) {
                    store.clear()
                    dismiss()
                }
                .disabled(!store.hasUnpinnedItems)
                .help("Removes every unpinned item from Files")
                .accessibilityHint("Removes every unpinned item from Files")
            } else {
                ShelfMenuRow(
                    systemImage: "trash.fill",
                    title: "Remove selected (\(store.selection.count))",
                    isDestructive: true
                ) {
                    store.removeSelected()
                    dismiss()
                }
                .help("Removes selected items from Files")
            }
            Divider().padding(.vertical, Space.half)
            Text("Tools".uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
                .padding(.horizontal, Space.one)
                .padding(.bottom, Space.quarter)
            hiddenFilesRow
        }
        .padding(.vertical, Space.half)
        .frame(minWidth: Layout.shelfMenuWidth)
    }

    private var hiddenFilesRow: some View {
        let isOn = hiddenFiles.hiddenFilesShown
        let isBusy = hiddenFiles.isToggling
        return Button {
            hiddenFiles.toggleHiddenFiles()
        } label: {
            HStack(spacing: Space.one) {
                Image(systemName: isOn ? "eye.slash" : "eye")
                    .fontWeight(.medium)
                    .frame(width: Layout.rowActionSize)
                Text("Show hidden files")
                Spacer(minLength: Space.one)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(isOn ? Color.accentColor : Color.secondary)
                } else if isOn {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .font(.caption)
            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
            .padding(.horizontal, Space.one)
            .padding(.vertical, Space.half)
            .frame(maxWidth: .infinity, minHeight: Layout.shelfMenuRowHeight)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(ShelfMenuRowStyle())
        .disabled(isBusy)
        .help(isOn ? "Hide hidden files — Finder will restart" : "Show hidden files — Finder will restart")
        .accessibilityLabel("Show hidden files")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint("Toggles Finder hidden files. Finder restarts to apply.")
    }
}

/// One row in the overflow menu: a leading symbol in a fixed column and a
/// title, with the row's hover fill. psymail's `MenuRow` is not exported by
/// `PsymailKit`, so this is CCP's own in that shape, in CCP tokens.
private struct ShelfMenuRow: View {
    let systemImage: String
    let title: String
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.one) {
                Image(systemName: systemImage)
                    .fontWeight(.medium)
                    .frame(width: Layout.rowActionSize)
                Text(title)
                Spacer(minLength: Space.one)
            }
            .font(.caption)
            .foregroundStyle(isDestructive ? Color.red : Color.primary)
            .padding(.horizontal, Space.one)
            .padding(.vertical, Space.half)
            .frame(maxWidth: .infinity, minHeight: Layout.shelfMenuRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(ShelfMenuRowStyle())
        .accessibilityLabel(title)
    }
}

private struct ShelfMenuRowStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                hovered || configuration.isPressed
                    ? Color.menuRowHover
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            )
            .onHover { hovered = $0 }
    }
}

/// The latest files in ~/Downloads, re-read every time the card appears.
/// Enumeration runs off the main thread so a crowded folder never blocks the
/// panel opening; thumbnails stay derived in the row, never stored.
@MainActor
@Observable
private final class RecentDownloadsStore {
    static let maxCount = 9

    var files: [RecentFile] = []

    func reload() async {
        let files = await Task.detached(priority: .utility, operation: Self.load).value
        guard !Task.isCancelled else { return }
        self.files = files
    }

    nonisolated private static func load() -> [RecentFile] {
        guard let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return []
        }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let dated = urls.compactMap { url -> (URL, Date, Bool)? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard let date = values?.contentModificationDate else { return nil }
            return (url, date, values?.isDirectory ?? false)
        }
        return dated
            .sorted { $0.1 > $1.1 }
            .prefix(maxCount)
            .map { RecentFile(url: $0.0, isDirectory: $0.2) }
    }
}

private struct RecentFile: Identifiable {
    let url: URL
    let isDirectory: Bool

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

private struct RecentDownloadRow: View {
    let file: RecentFile
    @Environment(\.isPanelEditing) private var isPanelEditing
    @State private var isHovered = false

    var body: some View {
        Button {
            if !isPanelEditing {
                NSWorkspace.shared.open(file.url)
            }
        } label: {
            HStack(spacing: Space.one) {
                iconPreview
                Text(file.name)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: Space.half)
                if isHovered {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, Space.quarter)
            .padding(.horizontal, Space.quarter)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPanelEditing)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(file.url) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
        }
        .accessibilityLabel(file.name)
        .accessibilityHint("Opens in its default app")
        .help(file.name)
        .modifier(RecentDownloadDragModifier(url: file.url))
    }

    @ViewBuilder
    private var iconPreview: some View {
        let previewSize = CGSize(width: Layout.shelfPreviewWidth, height: Layout.shelfPreviewHeight)
        Group {
            if file.isDirectory {
                Image(systemName: "folder.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: previewSize.width, height: previewSize.height)
            } else {
                FileThumbnailView(
                    url: file.url,
                    size: previewSize,
                    fallbackIcon: NSWorkspace.shared.icon(forFile: file.url.path),
                    symbolName: "doc.fill"
                )
            }
        }
        .frame(width: previewSize.width, height: previewSize.height)
    }
}

private struct RecentDownloadDragModifier: ViewModifier {
    let url: URL
    @Environment(\.isPanelEditing) private var isPanelEditing

    func body(content: Content) -> some View {
        if isPanelEditing {
            content
        } else {
            content.onDrag {
                let provider = NSItemProvider()
                provider.registerObject(url as NSURL, visibility: .all)
                provider.suggestedName = url.lastPathComponent
                return provider
            }
        }
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
        let previewSize = CGSize(width: Layout.shelfPreviewWidth, height: Layout.shelfPreviewHeight)
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

