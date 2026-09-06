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
///
/// Minimized, it is just the header plus one horizontally paging row of small
/// thumbnails: pins first, a divider, then recent downloads. Unpinned shelf
/// items hide entirely until the caret expands it again. With no pins and no
/// downloads it is just its header.
@MainActor
public final class ShelfWidget: CCPWidget {
    public static let descriptor = WidgetDescriptor(
        id: "shelf",
        title: "Files",
        symbolName: "folder.fill",
        // An empty shelf is a header and nothing else. The card grows to fit
        // its chips the moment something lands on it, so the declared size is
        // the floor for the empty case rather than a shape to fill.
        size: .compact,
        isMinimizable: true
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
    @Environment(\.panelArrangement) private var arrangement
    @Environment(\.currentWidgetID) private var currentWidgetID

    private var pinned: [ShelfItem] { store.items.filter(\.isPinned) }
    private var unpinned: [ShelfItem] { store.items.filter { !$0.isPinned } }

    /// Persisted on the layout's placement, so a minimized Files stays
    /// minimized across launches and travels with the widget between lanes.
    private var isMinimized: Bool {
        guard let arrangement, let id = currentWidgetID else { return false }
        return arrangement.layout.lanes.joined().first { $0.id == id }?.isMinimized ?? false
    }

    private func toggleMinimized() {
        guard let arrangement, let id = currentWidgetID else { return }
        arrangement.setMinimized(id, to: !isMinimized)
    }

    var body: some View {
        WidgetCard(ShelfWidget.descriptor, isMinimized: isMinimized, onToggleMinimized: toggleMinimized) {
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
            if isMinimized {
                // Pins then downloads in one paging row — unpinned shelf items
                // hide entirely. No pins and no downloads, no row: just the header.
                if !pinned.isEmpty || !downloads.files.isEmpty {
                    minimizedStrip(pinned: pinned, downloads: downloads.files)
                }
            } else if !store.items.isEmpty || !downloads.files.isEmpty {
                // Nothing below the header until something is anywhere: an empty
                // box explaining where to drop is the floating shelf's job, not a
                // second one here.
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
                        if !isPinnedCollapsed && (!unpinned.isEmpty || !downloads.files.isEmpty) {
                            Color.clear.frame(height: Space.oneHalf)
                        }
                    }
                    if !unpinned.isEmpty {
                        ForEach(unpinned.prefix(Self.maxSectionRows)) { item in
                            shelfRow(for: item)
                        }
                        moreLabel(remaining: unpinned.count - Self.maxSectionRows)
                        if !downloads.files.isEmpty {
                            Color.clear.frame(height: Space.oneHalf)
                        }
                    }
                    if !downloads.files.isEmpty {
                        shelfSectionHeader(title: "Downloads", isCollapsed: isDownloadsCollapsed) {
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
        .animation(.smooth(duration: 0.2), value: isMinimized)
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

    /// The minimized form: one horizontally paging row — pins first, a small
    /// divider, then recent downloads. Everything stays reachable: the row
    /// pages a viewport at a time rather than capping with "+N more".
    private func minimizedStrip(pinned: [ShelfItem], downloads: [RecentFile]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: Space.half) {
                ForEach(pinned) { item in
                    MinimizedShelfThumbnail(item: item)
                }
                if !pinned.isEmpty, !downloads.isEmpty {
                    Divider()
                        .frame(width: 1, height: Layout.shelfMinimizedThumbnailSize)
                        .accessibilityHidden(true)
                }
                ForEach(downloads) { file in
                    MinimizedDownloadThumbnail(file: file)
                }
            }
            .padding(.top, Space.half)
        }
        .scrollTargetBehavior(.paging)
        .transition(.blurReplace)
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
        .padding(.bottom, Space.half)
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
            PopoverMenuSectionLabel("Actions")
                .padding(.top, Space.half)
            PopoverMenuRow(
                systemImage: window.isVisible ? "xmark" : "arrow.up.forward",
                title: window.isVisible ? "Hide shelf" : "Open shelf"
            ) {
                window.toggle()
                dismiss()
            }
            .accessibilityHint(window.isVisible ? "Hides the floating Files window" : "Shows the floating Files window")
            if store.selection.isEmpty {
                PopoverMenuRow(systemImage: "trash", title: "Clear all", isDestructive: true) {
                    store.clear()
                    dismiss()
                }
                .disabled(!store.hasUnpinnedItems)
                .help("Removes every unpinned item from Files")
                .accessibilityHint("Removes every unpinned item from Files")
            } else {
                PopoverMenuRow(
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
            PopoverMenuSectionLabel("Tools")
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
        .buttonStyle(PopoverMenuRowStyle())
        .disabled(isBusy)
        .help(isOn ? "Hide hidden files — Finder will restart" : "Show hidden files — Finder will restart")
        .accessibilityLabel("Show hidden files")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint("Toggles Finder hidden files. Finder restarts to apply.")
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
                    Image(systemName: "arrow.up.forward")
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
        ShelfItemPreview(
            item: item,
            size: CGSize(width: Layout.shelfPreviewWidth, height: Layout.shelfPreviewHeight),
            fallbackPointSize: Layout.shelfPreviewIconSize
        )
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

/// One pin in the Files card's minimized strip: a small thumbnail that opens
/// on tap and drags out like a full row. The caret is the only way back to
/// the full card — tapping here never expands, it opens.
private struct MinimizedShelfThumbnail: View {
    let item: ShelfItem
    @Environment(ShelfStore.self) private var store
    @Environment(\.isPanelEditing) private var isPanelEditing
    @State private var showTitleTip = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Button {
            if !isPanelEditing {
                openShelfItem(item)
            }
        } label: {
            thumbnail
        }
        .buttonStyle(.plain)
        .disabled(isPanelEditing)
        .accessibilityLabel(item.title)
        .accessibilityHint(openHint)
        .popover(isPresented: $showTitleTip, arrowEdge: .bottom) {
            Text(item.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, Space.one)
                .padding(.vertical, Space.half)
                .frame(maxWidth: Layout.shelfMinimizedTipMaxWidth)
        }
        .onHover(perform: trackHover)
        .onDisappear { hoverTask?.cancel() }
        .contextMenu {
            if item.kind == .file, let path = item.filePath {
                Button("Open") { openShelfItem(item) }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Divider()
            } else if item.kind == .image {
                Button("Open") { openShelfItem(item) }
                Divider()
            } else if item.kind == .link {
                Button("Open") { openShelfItem(item) }
                Divider()
            } else if item.kind == .text {
                Button("Copy") { openShelfItem(item) }
                Divider()
            }
            Button(item.isPinned ? "Unpin" : "Pin") { store.togglePin(item.id) }
            Button("Remove", role: .destructive) { store.remove(item.id) }
        }
        .modifier(WidgetFileRowDragModifier(item: item))
    }

    private var thumbnail: some View {
        let edge = Layout.shelfMinimizedThumbnailSize
        return ShelfItemPreview(
            item: item,
            size: CGSize(width: edge, height: edge),
            fallbackPointSize: Layout.shelfMinimizedThumbnailIconSize
        )
    }

    private var openHint: String {
        switch item.kind {
        case .file, .image, .link: "Opens in its default app"
        case .text: "Copies to the clipboard"
        }
    }

    /// The title arrives a beat after the pointer lands — half a second, so
    /// sweeping across the strip stays quiet and only a resting pointer asks.
    /// A popover rather than `.help`: the system tooltip's delay is not
    /// ours to set, and an overlay would clip at the scroll view's edge.
    private func trackHover(_ hovering: Bool) {
        hoverTask?.cancel()
        hoverTask = nil
        guard hovering, !isPanelEditing else {
            showTitleTip = false
            return
        }
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            showTitleTip = true
        }
    }
}

/// One download in the Files card's minimized strip: a small thumbnail that
/// opens on tap and drags out like an expanded download row. Mirrors
/// MinimizedShelfThumbnail's hover title so the two halves of the strip agree.
private struct MinimizedDownloadThumbnail: View {
    let file: RecentFile
    @Environment(\.isPanelEditing) private var isPanelEditing
    @State private var showTitleTip = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Button {
            if !isPanelEditing {
                NSWorkspace.shared.open(file.url)
            }
        } label: {
            thumbnail
        }
        .buttonStyle(.plain)
        .disabled(isPanelEditing)
        .accessibilityLabel(file.name)
        .accessibilityHint("Opens in its default app")
        .popover(isPresented: $showTitleTip, arrowEdge: .bottom) {
            Text(file.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, Space.one)
                .padding(.vertical, Space.half)
                .frame(maxWidth: Layout.shelfMinimizedTipMaxWidth)
        }
        .onHover(perform: trackHover)
        .onDisappear { hoverTask?.cancel() }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(file.url) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
        }
        .modifier(RecentDownloadDragModifier(url: file.url))
    }

    @ViewBuilder
    private var thumbnail: some View {
        let edge = Layout.shelfMinimizedThumbnailSize
        let size = CGSize(width: edge, height: edge)
        if file.isDirectory {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: size.width, height: size.height)
        } else {
            FileThumbnailView(
                url: file.url,
                size: size,
                fallbackIcon: NSWorkspace.shared.icon(forFile: file.url.path),
                symbolName: "doc.fill",
                fallbackPointSize: Layout.shelfMinimizedThumbnailIconSize
            )
            .frame(width: size.width, height: size.height)
        }
    }

    private func trackHover(_ hovering: Bool) {
        hoverTask?.cancel()
        hoverTask = nil
        guard hovering, !isPanelEditing else {
            showTitleTip = false
            return
        }
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            showTitleTip = true
        }
    }
}

/// One shelf item's image, at any size: a stored preview, a QuickLook
/// thumbnail, the workspace icon, or the kind's symbol — derived in the view,
/// never stored. The full rows and the minimized strip draw through this one
/// view so the two never disagree about what an item looks like.
private struct ShelfItemPreview: View {
    let item: ShelfItem
    let size: CGSize
    let fallbackPointSize: CGFloat

    var body: some View {
        Group {
            if let preview = shelfPreviewImage(for: item) {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous))
            } else if item.kind == .file, let path = item.filePath {
                FileThumbnailView(
                    url: URL(fileURLWithPath: path),
                    size: size,
                    fallbackIcon: shelfFileTypeIcon(for: item),
                    symbolName: shelfSymbol(for: item),
                    fallbackPointSize: fallbackPointSize
                )
            } else if let icon = shelfFileTypeIcon(for: item) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: fallbackPointSize, height: fallbackPointSize)
                    .frame(width: size.width, height: size.height)
            } else {
                Image(systemName: shelfSymbol(for: item))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

private func shelfSymbol(for item: ShelfItem) -> String {
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

@MainActor
private func shelfPreviewImage(for item: ShelfItem) -> NSImage? {    if item.kind == .image, let name = item.imageFileName {
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

private func shelfFileTypeIcon(for item: ShelfItem) -> NSImage? {
    guard item.kind == .file, let path = item.filePath else { return nil }
    return NSWorkspace.shared.icon(forFile: path)
}

/// Opens a shelf item the way the floating shelf's own rows do: files and
/// images in their default app, links in the browser, text onto the clipboard.
@MainActor
private func openShelfItem(_ item: ShelfItem) {
    switch item.kind {
    case .file:
        if let path = item.filePath {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    case .image:
        if let name = item.imageFileName {
            NSWorkspace.shared.open(ShelfStore.storeDirectory.appendingPathComponent(name))
        }
    case .link:
        if let s = item.urlString, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    case .text:
        if let text = item.text {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

private struct FileThumbnailView: View {
    let url: URL
    let size: CGSize
    let fallbackIcon: NSImage?
    let symbolName: String
    var fallbackPointSize: CGFloat = Layout.shelfPreviewIconSize
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
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous))
            } else if attempted {
                Group {
                    if let icon = fallbackIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: fallbackPointSize, height: fallbackPointSize)
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

