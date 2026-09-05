// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// The column of note tabs down the leading edge of the Notes card.
///
/// The rail never scrolls: the note count is capped low enough that every tab
/// plus the new-note row fits beside the editor, so the tab card stays a
/// short fixed column rather than growing a scroll region of its own.
struct NoteTabRail: View {
    @Bindable var adapter: NotesAdapter
    let onCloseRequest: (Note) -> Void

    @State private var renaming: UUID?
    @State private var renameDraft = ""
    @FocusState private var isRenaming: Bool

    var body: some View {
        VStack(spacing: Self.rowSpacing) {
            ForEach(adapter.notes) { note in
                row(note)
            }
            newNoteButton
            Spacer(minLength: 0)
        }
        // The note tucks over this card's trailing edge, so the rail's
        // content ends where the overlap begins: a close button half under
        // the note is a control that looks broken and lands half its taps on
        // the wrong card.
        .padding(.trailing, Layout.noteTuck)
    }

    /// The gap between tab rows.
    static let rowSpacing = Space.quarter

    // MARK: Rows

    @ViewBuilder
    private func row(_ note: Note) -> some View {
        let isSelected = adapter.selectedNoteID == note.id
        HStack(spacing: Space.quarter) {
            if renaming == note.id {
                renameField(note)
            } else {
                Text(note.name)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                closeButton(note)
            }
        }
        .padding(.horizontal, Space.half)
        .frame(height: Layout.noteTabHeight)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginRename(note) }
        .onTapGesture { adapter.selectNote(note.id) }
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

    private func closeButton(_ note: Note) -> some View {
        Button {
            onCloseRequest(note)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .frame(width: Space.oneHalf, height: Space.oneHalf)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .disabled(!adapter.canCloseNote)
        .opacity(adapter.canCloseNote ? 1 : 0)
        .help("Close note")
        .accessibilityLabel("Close \(note.name)")
    }

    private var newNoteButton: some View {
        Button {
            adapter.createNote()
        } label: {
            Label("New Note", systemImage: "plus")
                .font(.caption.weight(.semibold))
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
                .frame(height: Layout.noteTabHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!adapter.canCreateNote)
        .help(adapter.canCreateNote ? "New note" : "Note limit reached (\(NotesDocument.maximumNoteCount))")
        .accessibilityLabel("New note")
    }

    // MARK: Renaming

    private func beginRename(_ note: Note) {
        // One draft and one focus flag serve every row, so moving straight
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
