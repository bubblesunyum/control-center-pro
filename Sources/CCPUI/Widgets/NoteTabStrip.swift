// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// The notes' tabs as a horizontal strip living in the widget header.
///
/// The strip never wraps: twelve tabs overflow a lane, so it scrolls and
/// follows the selection. The selected tab wears a muted fill — the header's
/// answer to "where am I" now that there is no title beside it.
struct NoteTabStrip: View {
    @Bindable var adapter: NotesAdapter
    let onCloseRequest: (Note) -> Void

    @State private var renaming: UUID?
    @State private var renameDraft = ""
    @State private var hoveredNoteID: UUID?
    @FocusState private var isRenaming: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.quarter) {
                    ForEach(adapter.notes) { note in
                        tab(note)
                            .id(note.id)
                    }
                }
                .padding(.vertical, Space.quarter / 2)
            }
            .onChange(of: adapter.selectedNoteID) { _, selected in
                guard let selected else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(selected, anchor: .center)
                }
            }
        }
    }

    // MARK: Tabs

    @ViewBuilder
    private func tab(_ note: Note) -> some View {
        let isSelected = adapter.selectedNoteID == note.id
        let isHovered = hoveredNoteID == note.id
        let showClose = adapter.canCloseNote && (isSelected || isHovered)
        HStack(spacing: Space.quarter) {
            if renaming == note.id {
                renameField(note)
            } else {
                Text(note.name)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showClose {
                    Button {
                        onCloseRequest(note)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .frame(width: Space.one, height: Space.one)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Close note")
                    .accessibilityLabel("Close \(note.name)")
                }
            }
        }
        .padding(.leading, Space.one)
        .padding(.trailing, showClose || renaming == note.id ? Space.half : Space.one)
        .frame(minWidth: 36, maxWidth: 96)
        .frame(height: Layout.noteTabHeight)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .background {
            RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
                .fill(isSelected ? Color.controlFill : isHovered ? Color.controlFill.opacity(0.5) : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous))
        .onTapGesture(count: 2) { beginRename(note) }
        .onTapGesture { adapter.selectNote(note.id) }
        .onHover { hovering in
            if hovering { hoveredNoteID = note.id } else if hoveredNoteID == note.id { hoveredNoteID = nil }
        }
        .contextMenu {
            Button("Rename") { beginRename(note) }
            Button("Delete", role: .destructive) { onCloseRequest(note) }
                .disabled(!adapter.canCloseNote)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(note.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func renameField(_ note: Note) -> some View {
        TextField("", text: $renameDraft)
            .textFieldStyle(.plain)
            .font(.caption)
            .focused($isRenaming)
            .onSubmit { commitRename(note) }
            .onExitCommand { renaming = nil }
            .onChange(of: isRenaming) { _, focused in
                if !focused { commitRename(note) }
            }
            .accessibilityLabel("Note name")
    }

    // MARK: Renaming

    private func beginRename(_ note: Note) {
        // One draft and one focus flag serve every tab, so moving straight
        // from renaming one tab to renaming another never blurs the first —
        // `isRenaming` is already true and `onChange` does not fire. Commit it
        // here instead of dropping what the user typed.
        if let inFlight = renaming, inFlight != note.id,
           let previous = adapter.notes.first(where: { $0.id == inFlight }) {
            commitRename(previous)
        }
        adapter.selectNote(note.id)
        renameDraft = note.name
        renaming = note.id
        isRenaming = true
    }

    private func commitRename(_ note: Note) {
        guard renaming == note.id else { return }
        renaming = nil
        adapter.renameNote(note.id, to: renameDraft)
    }
}
