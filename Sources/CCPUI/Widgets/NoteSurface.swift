// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// The rail of tabs and the note as two objects, not one: the tab list is its
/// own card floating beneath the note, offset left so only its trailing edge
/// tucks under it. The note sits above in the z-order, and the selected tab's
/// name row is where the two visibly meet — joined by overlap rather than by
/// a shared outline, so each container carries its own elevation.
struct NoteSurface: View {
    @Bindable var adapter: NotesAdapter
    let onCloseRequest: (Note) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: -Layout.noteTuck) {
            tabs
                .zIndex(0)
            note
                .zIndex(1)
        }
        // The join no longer slides anywhere, but the selected row still
        // cross-fades.
        .animation(.snappy(duration: 0.22), value: adapter.selectedNoteID)
    }

    /// The tab list as its own card.
    private var tabs: some View {
        NoteTabRail(adapter: adapter, onCloseRequest: onCloseRequest)
            .frame(width: Layout.noteTabRailWidth)
            .noteCardChrome()
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
        .noteCardChrome()
    }
}

/// The skin both Notes containers share: the fills, hairline and shadow the
/// single surface used to draw once, now drawn per piece now that the two
/// honestly overlap.
private struct NoteCardChrome: ViewModifier {    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        content
            .background(shape.fill(Color.controlFill))
            .background(shape.fill(.background.opacity(0.35)))
            .background(shape.fill(Color.noteScrim))
            .overlay(shape.stroke(Color.cardStroke, lineWidth: Stroke.hairline))
            .shadow(color: .cardShadow, radius: Space.one, y: Space.quarter)
    }
}

private extension View {
    func noteCardChrome() -> some View {
        modifier(NoteCardChrome())
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
