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

/// The skin of the inset well: the scrim alone, no lightening and no shadow.
/// A raised surface lightens the glass and casts a shadow; a hollow darkens
/// it and casts none.
private struct NoteInsetChrome: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        content
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
            NoteToolbarButton("trash", label: "Clear") { adapter.clear() }
            Spacer(minLength: 0)
            NoteToolbarButton(didCopy ? "checkmark" : "doc.on.doc",
                              label: didCopy ? "Copied" : "Copy",
                              tint: didCopy ? .green : nil) {
                adapter.copyAll()
                withAnimation(.easeOut(duration: 0.15)) { didCopy = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1200))
                    withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
                }
            }
            NoteToolbarButton("square.and.arrow.down", label: "Export") { adapter.exportText() }
        }
        .padding(.horizontal, Space.one)
        .padding(.bottom, Space.one)
        .disabled(isEmpty)
        .opacity(isEmpty ? 0.5 : 1)
    }
}

/// One button in the note's bottom toolbar, wearing the same hover chip as
/// the header's plus — one step brighter, over a muted fill.
private struct NoteToolbarButton: View {
    private let symbol: String
    private let label: String
    private let tint: Color?
    private let action: () -> Void

    @State private var isHovered = false

    init(_ symbol: String, label: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption)
                .frame(width: Layout.rowActionSize, height: Layout.rowActionSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? (isHovered ? Color.primary : Color.secondary))
        .background {
            RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
                .fill(isHovered ? Color.controlFill : Color.clear)
        }
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
