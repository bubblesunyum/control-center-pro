// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// The notes' tabs as a horizontal strip living in the widget header.
///
/// The selected tab wears a muted fill — the header's answer to "where am I"
/// now that there is no title beside it — and a plain plus hugs the last tab.
/// Twelve tabs never fit a lane, so past what fits the strip scrolls under a
/// pinned plus instead of pushing it off the edge, and follows the selection.
struct NoteTabStrip: View {
    @Bindable var adapter: NotesAdapter
    let onCloseRequest: (Note) -> Void

    @State private var renaming: UUID?
    @State private var renameDraft = ""
    @State private var hoveredNoteID: UUID?
    @State private var hoveredCloseID: UUID?
    @FocusState private var isRenaming: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.quarter) {
                tabViews
                plusButton
            }
            HStack(spacing: Space.half) {
                scrollingTabs
                plusButton
            }
        }
    }

    /// The tabs at their natural width, for the fit the strip prefers.
    @ViewBuilder
    private var tabViews: some View {
        ForEach(adapter.notes) { note in
            tab(note)
        }
    }

    /// The tabs under a scroll view, for when there are more than fit.
    @ViewBuilder
    private var scrollingTabs: some View {
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

    private var plusButton: some View {
        Button {
            adapter.createNote()
        } label: {
            Image(systemName: "plus")
                .font(.caption.weight(.semibold))
                .frame(width: Layout.rowActionSize, height: Layout.rowActionSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!adapter.canCreateNote)
        .help(adapter.canCreateNote ? "New note" : "Note limit reached (\(NotesDocument.maximumNoteCount))")
        .accessibilityLabel("New note")
    }

    // MARK: Tabs

    @ViewBuilder
    private func tab(_ note: Note) -> some View {
        let isSelected = adapter.selectedNoteID == note.id
        let isHovered = hoveredNoteID == note.id
        // The close control never leaves the layout — it only fades. Adding
        // and removing it resized the pill and the name jumped under the eye.
        let closeOpacity: CGFloat = (isSelected || isHovered) ? 1 : 0
        let isCloseHovered = hoveredCloseID == note.id
        HStack(spacing: Space.half) {
            if renaming == note.id {
                renameField(note)
            } else {
                Text(note.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if adapter.canCloseNote {
                    Button {
                        onCloseRequest(note)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .padding(Space.half)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isCloseHovered ? .secondary : .tertiary)
                    .background {
                        RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
                            .fill(isCloseHovered ? Color.controlFill : Color.clear)
                    }
                    .onHover { hovering in
                        if hovering { hoveredCloseID = note.id }
                        else if hoveredCloseID == note.id { hoveredCloseID = nil }
                    }
                    .opacity(closeOpacity)
                    .disabled(closeOpacity == 0)
                    .accessibilityHidden(closeOpacity == 0)
                    .help("Close note")
                    .accessibilityLabel("Close \(note.name)")
                }
            }
        }
        // The hover chip is a 20pt square in a 24pt pill, so 2pt of air above
        // and below it — the trailing pad hugs tighter at a point, half the
        // top/bottom air, so the pill ends where the chip ends.
        .padding(.leading, Space.quarter)
        .padding(.trailing, Space.quarter / 2)
        .frame(maxWidth: 92)
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
            .font(.headline)
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
