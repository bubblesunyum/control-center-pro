// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI
import AppKit

/// Notes: short-lived text — meeting notes, numbers, fragments on their way
/// somewhere else — written in the panel and kept in tabs.
///
/// UI is pulled from Vorssaint's floating scratchpad but reshaped as a lane
/// widget: the floating panel's chrome (pin, drag handle, resize overlay, HUD
/// backdrop) is gone, and the editor lives inside the shared `WidgetCard` glass
/// so the note reads as one more control-center tile rather than a window
/// inside a window. Document mechanics (tabs, retention, debounced UserDefaults
/// persistence) are the same values Vorssaint uses, via `NotesAdapter`, so a
/// note written here is there in the floating pad and vice-versa.
@MainActor
public final class NotesWidget: CCPWidget {
    public static let descriptor = WidgetDescriptor(
        // The id is stored in every saved layout, so it stays what it has
        // always been even though the widget is now called Notes.
        id: "scratchpad",
        title: "Notes",
        symbolName: "note.text",
        size: .tall
    )

    private let adapter: NotesAdapter

    public init() {
        self.adapter = NotesAdapter()
    }

    /// Test seam: widget backed by an in-memory document.
    init(document: NotesDocument) {
        self.adapter = NotesAdapter(document: document)
    }

    init(adapter: NotesAdapter) {
        self.adapter = adapter
    }

    public func makeView() -> some View {
        NotesContent(adapter: adapter)
    }

    public func activate() { adapter.activate() }
    public func deactivate() { adapter.deactivate() }
}

// MARK: - Content

private struct NotesContent: View {
    @Bindable var adapter: NotesAdapter
    @State private var didCopy = false
    @State private var dialog: NoteDialog?
    @State private var renameDraft = ""
    @State private var hoveredNoteID: UUID?

    private var isEmpty: Bool { adapter.text.isEmpty }

    var body: some View {
        WidgetCard(NotesWidget.descriptor) {
            VStack(alignment: .leading, spacing: Space.one) {
                tabBar
                editor
                footer
            }
        }
        .alert(dialogTitle, isPresented: dialogIsPresented) {
            switch dialog {
            case .rename(let note):
                TextField(note.name, text: $renameDraft)
                Button("Cancel", role: .cancel) { dismissDialog() }
                Button("Save") {
                    adapter.renameNote(note.id, to: renameDraft)
                    dismissDialog()
                }
            case .close(let note):
                Button("Cancel", role: .cancel) { dismissDialog() }
                Button("Close Note", role: .destructive) {
                    _ = adapter.closeNote(note.id)
                    dismissDialog()
                }
            case nil:
                EmptyView()
            }
        } message: {
            if case .close(let note) = dialog {
                Text("Close “\(note.name)”? Its text will be lost.")
            }
        }
    }

    // MARK: Tab bar — pulled from upstream's tab strip, compressed for 240pt

    private var tabBar: some View {
        HStack(spacing: Space.half) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.half - Space.quarter) {
                        ForEach(adapter.notes) { note in
                            tabButton(note)
                                .id(note.id)
                        }
                    }
                    .padding(.vertical, Space.quarter)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onAppear {
                    guard let selected = adapter.selectedNoteID else { return }
                    proxy.scrollTo(selected, anchor: .center)
                }
                .onChange(of: adapter.selectedNoteID) { _, selected in
                    guard let selected else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(selected, anchor: .center)
                    }
                }
            }

            Button {
                adapter.createNote()
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: Layout.rowActionSize, height: Layout.rowActionSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!adapter.canCreateNote)
            .help(adapter.canCreateNote ? "New note" : "Note limit reached (\(NotesDocument.maximumNoteCount))")
            .accessibilityLabel("New note")

            Menu {
                if let selectedNote {
                    Button("Rename Note") { presentRename(selectedNote) }
                    Button("Close Note", role: .destructive) { requestClose(selectedNote) }
                        .disabled(!adapter.canCloseNote)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .frame(width: Layout.rowActionSize, height: Layout.rowActionSize)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Note actions")
            .accessibilityLabel("Note actions")
        }
        .frame(height: 28)
    }

    private func tabButton(_ note: Note) -> some View {
        let selected = adapter.selectedNoteID == note.id
        let isHovered = hoveredNoteID == note.id
        let showClose = adapter.canCloseNote && (isHovered || selected)
        return HStack(spacing: Space.quarter) {
            Text(note.name)
                .font(.caption.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            if showClose {
                Button {
                    requestClose(note)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: Layout.rowActionSize, height: Layout.rowActionSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close note")
                .accessibilityLabel("Close note")
            }
        }
        .padding(.leading, Space.one)
        .padding(.trailing, showClose ? Space.half : Space.one)
        .frame(minWidth: 36, maxWidth: 96)
        .frame(height: Layout.rowActionSize)
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .background {
            RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
                .fill(selected ? Color.selectedFill : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous))
        .onTapGesture { adapter.selectNote(note.id) }
        .onHover { hovering in
            if hovering { hoveredNoteID = note.id } else if hoveredNoteID == note.id { hoveredNoteID = nil }
        }
        .contextMenu {
            Button("Rename Note") { presentRename(note) }
            Button("Close Note", role: .destructive) { requestClose(note) }
                .disabled(!adapter.canCloseNote)
        }
        .accessibilityLabel(note.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAddTraits(.isButton)
    }

    private var selectedNote: Note? {
        adapter.notes.first(where: { $0.id == adapter.selectedNoteID })
    }

    // MARK: Dialog

    private var dialogTitle: String {
        switch dialog {
        case .rename: return "Rename Note"
        case .close: return "Close Note"
        case nil: return ""
        }
    }

    private var dialogIsPresented: Binding<Bool> {
        Binding(get: { dialog != nil }, set: { if !$0 { dismissDialog() } })
    }

    private func presentRename(_ note: Note) {
        renameDraft = note.name
        dialog = .rename(note)
    }

    private func requestClose(_ note: Note) {
        guard adapter.canCloseNote else { return }
        if !NotesSupport.requiresCloseConfirmation(note) {
            _ = adapter.closeNote(note.id)
        } else {
            dialog = .close(note)
        }
    }

    private func dismissDialog() { dialog = nil }

    // MARK: Editor — live-styled markdown surface

    private var editor: some View {
        MarkdownNoteEditor(
            text: Binding(get: { adapter.text }, set: { adapter.text = $0 }),
            documentId: adapter.selectedNoteID?.uuidString ?? "notes",
            placeholder: "Write something…"
        )
        .frame(height: Layout.noteEditorHeight)
        .background(Color.controlFill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(Color.cardStroke.opacity(0.6), lineWidth: 1)
        )
        .accessibilityLabel("Note text")
        .accessibilityHint("Editable Markdown notes")
    }

    // MARK: Footer — copy, export, clear

    private var footer: some View {
        HStack(spacing: Space.half) {
            footerButton(didCopy ? "checkmark" : "doc.on.doc",
                         label: didCopy ? "Copied" : "Copy",
                         tint: didCopy ? .green : nil) {
                adapter.copyAll()
                withAnimation(.easeOut(duration: 0.15)) { didCopy = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1200))
                    withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
                }
            }
            footerButton("square.and.arrow.down", label: "Export") {
                adapter.exportText()
            }
            Spacer(minLength: 0)
            footerButton("trash", label: "Clear") {
                adapter.clear()
            }
        }
        .disabled(isEmpty)
        .opacity(isEmpty ? 0.5 : 1)
    }

    private func footerButton(_ symbol: String, label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private enum NoteDialog: Equatable {
    case rename(Note)
    case close(Note)
}
