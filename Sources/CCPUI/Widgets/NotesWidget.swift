// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// Notes: short-lived text — meeting notes, numbers, fragments on their way
/// somewhere else — written in the panel and kept in tabs.
///
/// The tabs live in the header as a horizontal strip, in place of a title:
/// the selected tab wears a muted fill, a plain plus beside it makes a new
/// note, and the way out to Craft stays on the trailing edge. Under the
/// header the note sits as a single inset well. ``NoteSurface`` owns that
/// well.
///
/// Document mechanics (tabs, retention, debounced UserDefaults persistence) are
/// the values Vorssaint's floating pad uses, via `NotesAdapter`, so a note
/// written here is there and vice-versa.
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
    @State private var noteToClose: Note?

    @Environment(\.panelEditor) private var panelEditor
    @Environment(\.currentWidgetID) private var currentWidgetID

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Space.one) {
                header
                NoteSurface(adapter: adapter)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Space.oneHalf)
        }
        .alert("Delete Note", isPresented: isConfirmingClose, presenting: noteToClose) { note in
            Button("Cancel", role: .cancel) { noteToClose = nil }
            Button("Delete", role: .destructive) {
                _ = adapter.closeNote(note.id)
                noteToClose = nil
            }
        } message: { note in
            Text("Delete “\(note.name)”? Its text will be lost.")
        }
    }

    /// The header is the tab strip, not a title: the widget's icon, its tabs
    /// with the plus hugging the last one, then the way out to Craft. It
    /// still publishes the header frame the panel's hold-to-edit hit-tests
    /// against, and it keeps the hold accessibility action — a custom header
    /// that drops either silently leaves the widget undraggable.
    private var header: some View {
        HStack(spacing: Space.one) {
            Image(systemName: NotesWidget.descriptor.symbolName)
                .font(.headline)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            NoteTabStrip(adapter: adapter, onCloseRequest: requestClose)
            Spacer(minLength: 0)
            HeaderIconButton(systemImage: "arrow.up.forward.app", label: "Open in Craft") {
                adapter.openCraft()
            }
        }
        .frame(minHeight: Layout.headerAccessorySize)
        .contentShape(Rectangle())
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: HeaderFramePreference.self,
                    value: currentWidgetID.map { [HeaderFrame(id: $0, frame: proxy.frame(in: .panel))] } ?? []
                )
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Hold to edit widgets")
        .accessibilityAction {
            guard let editor = panelEditor, !editor.isEditing else { return }
            withAnimation(.snappy) { editor.startEditing() }
        }
        .animation(.snappy(duration: 0.22), value: adapter.selectedNoteID)
    }

    /// An empty note goes without asking; only text that would be lost is worth
    /// a dialog.
    private func requestClose(_ note: Note) {
        guard adapter.canCloseNote else { return }
        if NotesSupport.requiresCloseConfirmation(note) {
            noteToClose = note
        } else {
            _ = adapter.closeNote(note.id)
        }
    }

    private var isConfirmingClose: Binding<Bool> {
        Binding(get: { noteToClose != nil }, set: { if !$0 { noteToClose = nil } })
    }
}
