// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// The note itself as a single well set into the card.
///
/// The tabs live up in the header now, so there is no rail to join to — just
/// one inset surface carrying the editor over its toolbar. It reads as inset
/// because it is darker than the glass around it, with no drop shadow of its
/// own.
struct NoteSurface: View {
    @Bindable var adapter: NotesAdapter

    var body: some View {
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
        .noteInsetChrome()
    }
}

/// The skin of the inset well: the same lightening the card draws, pulled back
/// down by a heavier scrim, under a hairline and no shadow — a raised surface
/// casts one, a hollow one does not.
private struct NoteInsetChrome: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        content
            .background(shape.fill(Color.controlFill))
            .background(shape.fill(Color.noteInset))
            .overlay(shape.stroke(Color.cardStroke, lineWidth: Stroke.hairline))
    }
}

private extension View {
    func noteInsetChrome() -> some View {
        modifier(NoteInsetChrome())
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
        .padding(.horizontal, Space.one)
        .padding(.bottom, Space.one)
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
