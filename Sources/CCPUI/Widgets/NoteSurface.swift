// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// The rail of tabs and the note, drawn as one raised object above the Notes
/// card: the selected tab is the note's front edge, and the two share a single
/// outline supplied by ``NoteJoinedShape``.
struct NoteSurface: View {
    @Bindable var adapter: NotesAdapter
    let onCloseRequest: (Note) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            NoteTabRail(adapter: adapter, onCloseRequest: onCloseRequest)
                .frame(width: Layout.noteTabRailWidth)
            note
        }
        .background(joined.fill(Color.controlFill))
        .background(joined.fill(.background.opacity(0.35)))
        .background(joined.fill(Color.noteScrim))
        .overlay(joined.stroke(Color.cardStroke, lineWidth: Stroke.hairline))
        .shadow(color: .cardShadow, radius: Space.one, y: Space.quarter)
        .animation(.snappy(duration: 0.22), value: adapter.selectedNoteID)
    }

    private var joined: NoteJoinedShape {
        NoteJoinedShape(tabTop: NoteTabRail.tabTop(forIndex: selectedIndex),
                        railWidth: Layout.noteTabRailWidth,
                        tabHeight: Layout.noteTabHeight,
                        radius: Radius.control)
    }

    private var selectedIndex: Int {
        adapter.notes.firstIndex { $0.id == adapter.selectedNoteID } ?? 0
    }

    // MARK: The note

    private var note: some View {
        VStack(spacing: 0) {
            MarkdownNoteEditor(
                text: Binding(get: { adapter.text }, set: { adapter.text = $0 }),
                documentId: adapter.selectedNoteID?.uuidString ?? "notes",
                placeholder: "Write something…"
            )
            // The card takes whatever height its lane gives it, and the editor
            // takes all of that: pinned to its floor instead, the note grows a
            // strip of container below the text that looks editable and
            // swallows the click.
            .frame(minHeight: Layout.noteEditorHeight, maxHeight: .infinity)
            .accessibilityLabel("Note text")
            .accessibilityHint("Editable Markdown")

            NoteToolbar(adapter: adapter)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The note's own toolbar, along its bottom edge.
private struct NoteToolbar: View {
    @Bindable var adapter: NotesAdapter
    @State private var didCopy = false

    private var isEmpty: Bool { adapter.text.isEmpty }

    var body: some View {
        HStack(spacing: Space.half) {
            button("trash", label: "Clear") { adapter.clear() }
            Spacer(minLength: 0)
            button(didCopy ? "checkmark" : "doc.on.doc",
                   label: didCopy ? "Copied" : "Copy",
                   tint: didCopy ? .green : nil) {
                adapter.copyAll()
                withAnimation(.easeOut(duration: 0.15)) { didCopy = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1200))
                    withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
                }
            }
            button("square.and.arrow.down", label: "Export") { adapter.exportText() }
        }
        .padding(.horizontal, Space.half)
        .padding(.bottom, Space.half)
        .disabled(isEmpty)
        .opacity(isEmpty ? 0.5 : 1)
    }

    private func button(_ symbol: String, label: String, tint: Color? = nil,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .frame(width: Layout.rowActionSize, height: Layout.rowActionSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
