// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// Clipboard history — the first widget that keeps sampling while the panel is
/// shut so entries are warm when the panel opens.
///
/// Warm because the user copies while the panel is down; showing history only
/// accumulated while the panel was open would show nothing the first time.
@MainActor
public final class ClipboardWidget: CCPWidget {
    public static let descriptor = WidgetDescriptor(
        id: "clipboard",
        title: "Clipboard",
        symbolName: "doc.on.clipboard",
        size: .tall
    )

    private let adapter: ClipboardAdapter

    public init() {
        self.adapter = ClipboardAdapter()
    }

    /// Test seam: a widget backed by a fake source.
    init(source: ClipboardSource) {
        self.adapter = ClipboardAdapter(source: source)
    }

    public func makeView() -> some View {
        ClipboardContent(adapter: adapter)
    }

    public func activate() { adapter.activate() }
    public func deactivate() { adapter.deactivate() }
}

// MARK: - Content

private struct ClipboardContent: View {
    @Bindable var adapter: ClipboardAdapter
    @State private var query = ""

    private var filtered: [ClipboardEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return adapter.entries }
        let lower = trimmed.lowercased()
        return adapter.entries.filter { $0.preview.lowercased().contains(lower) || $0.text.lowercased().contains(lower) }
    }

    private var pinned: [ClipboardEntry] { filtered.filter(\.isPinned) }
    private var recent: [ClipboardEntry] { filtered.filter { !$0.isPinned } }

    var body: some View {
        WidgetCard(ClipboardWidget.descriptor) {
            HStack(spacing: Space.half) {
                Text("\(adapter.entries.count) items")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel("\(adapter.entries.count) clipboard items")
                if adapter.entries.contains(where: { !$0.isPinned }) {
                    Button("Clear") { adapter.clearRecent() }
                        .font(.caption2.weight(.medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear recent clipboard items")
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: Space.one) {
                searchField
                entriesList
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: Space.half) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search", text: $query)
                .font(.caption)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search clipboard history")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Space.one)
        .padding(.vertical, Space.half)
        .background(Color.controlFill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    @ViewBuilder
    private var entriesList: some View {
        if !adapter.isHistoryEnabled {
            disabledState
        } else if adapter.entries.isEmpty {
            emptyState
        } else if filtered.isEmpty {
            Text("No matches")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, Space.one)
                .accessibilityLabel("No clipboard results for search")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 0).id("ccp.clipboard.top")
                        LazyVStack(alignment: .leading, spacing: Space.half) {
                            if !pinned.isEmpty {
                                sectionLabel("Pinned")
                                ForEach(pinned) { entry in
                                    ClipboardRow(entry: entry, adapter: adapter)
                                }
                                if !recent.isEmpty {
                                    Divider().padding(.vertical, Space.half)
                                }
                            }
                            if !recent.isEmpty {
                                if !pinned.isEmpty { sectionLabel("Recent") }
                                ForEach(recent) { entry in
                                    ClipboardRow(entry: entry, adapter: adapter)
                                }
                            }
                        }
                        .padding(.top, Space.quarter)
                    }
                }
                .frame(maxHeight: Layout.clipboardListHeight)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .id("clipboard-\(adapter.hideGeneration)")
                .onChange(of: adapter.hideGeneration) { _, _ in
                    proxy.scrollTo("ccp.clipboard.top", anchor: .top)
                }
            }
        }
    }

    private var disabledState: some View {
        VStack(spacing: Space.half) {
            Image(systemName: "doc.on.clipboard")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("Clipboard history is off")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Button("Enable") { adapter.enableHistory() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel("Enable clipboard history")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.one)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: Space.half) {
            Image(systemName: "doc.on.clipboard")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text("No clipboard history yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Copy something and it will appear here.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.one)
        .accessibilityElement(children: .combine)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
            .padding(.horizontal, Space.half)
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardEntry
    @Bindable var adapter: ClipboardAdapter
    @State private var didCopy = false
    @State private var copyTask: Task<Void, Never>?
    @Environment(\.hidePanel) private var hidePanel
    @Environment(\.pasteIntoPreviousApp) private var pasteIntoPreviousApp
    @Environment(\.isPanelEditing) private var isPanelEditing

    var body: some View {
        Button { isPanelEditing ? copyOnly() : copyAndPaste() } label: { rowContent }
            .buttonStyle(.plain)
            .disabled(isPanelEditing)
            .accessibilityLabel(
                [entry.isPinned ? "Pinned" : nil, entry.preview]
                    .compactMap { $0 }.joined(separator: " ")
            )
            .accessibilityHint("Copies and pastes into previous app. Right-click for more actions")
            .padding(.horizontal, Space.one)
            .padding(.vertical, Space.half)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(entry.isPinned ? Color.pinnedFill : Color.controlFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(entry.isPinned ? Color.pinnedStroke : Color.clear, lineWidth: Stroke.hairline)
            )
            .contentShape(Rectangle())
            .help(tooltipText)
            .contextMenu {
                Button(entry.isPinned ? "Unpin" : "Pin") { adapter.togglePin(entry) }
                Button("Copy") { copyOnly() }
                Divider()
                Button("Delete", role: .destructive) { adapter.remove(entry) }
            }
            .accessibilityAction(named: entry.isPinned ? "Unpin" : "Pin") { adapter.togglePin(entry) }
            .accessibilityAction(named: "Copy") { copyAndPaste() }
            .accessibilityAction(named: "Delete") { adapter.remove(entry) }
            .accessibilityElement(children: .contain)
            .overlay(alignment: .topTrailing) {
                if didCopy {
                    Text("Copied")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, Space.one - Space.quarter)
                        .padding(.vertical, Space.quarter + 1)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                        .offset(x: -Space.half, y: Space.half)
                        .transition(.opacity.combined(with: .scale))
                }
            }
            .animation(.easeOut(duration: 0.2), value: didCopy)
            .onDisappear { copyTask?.cancel() }
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: Space.one) {
            VStack(alignment: .leading, spacing: Space.quarter) {
                Text(entry.preview)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                if entry.kind == .files, !entry.filePaths.isEmpty {
                    Text(entry.filePaths.count == 1 ? ((entry.filePaths.first.map { ($0 as NSString).lastPathComponent } ) ?? entry.preview) : "\(entry.filePaths.count) files")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let thumb = adapter.thumbnail(for: entry) {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: Layout.clipboardThumbnailWidth, maxHeight: Layout.clipboardThumbnailHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private var menuFullText: String {
        guard entry.text.count > 4_000 else { return entry.text }
        return String(entry.text.prefix(4_000)) + "… (\(entry.text.count) chars)"
    }

    private var tooltipText: String {
        switch entry.kind {
        case .text:
            return menuFullText
        case .image:
            return entry.preview
        case .files:
            guard !entry.filePaths.isEmpty else { return entry.preview }
            let names = entry.filePaths.map { ($0 as NSString).lastPathComponent }
            let joined = names.joined(separator: "\n")
            guard joined.count > 4_000 else { return joined }
            return String(joined.prefix(4_000)) + "…"
        }
    }

    private func copyAndPaste() {
        hidePanel?()
        adapter.copy(entry) { success in
            guard success else { return }
            copyTask?.cancel()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { didCopy = true }
            copyTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
            }
            pasteIntoPreviousApp?()
        }
    }

    private func copyOnly() {
        adapter.copy(entry) { success in
            guard success else { return }
            copyTask?.cancel()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { didCopy = true }
            copyTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
            }
        }
    }
}
