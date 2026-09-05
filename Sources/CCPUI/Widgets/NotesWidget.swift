// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// Notes: short-lived text — meeting notes, numbers, fragments on their way
/// somewhere else — written in the panel and kept in tabs.
///
/// The card is two objects rather than one. The Notes card carries the title
/// and the way out to Craft; raised above it, a rail of tabs and the note it
/// belongs to share a single outline, so the selected tab reads as the note's
/// front edge. ``NoteSurface`` owns that pair.
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

    var body: some View {
        WidgetCard(NotesWidget.descriptor) {
            HeaderIconButton(systemImage: "arrow.up.forward.app", label: "Open in Craft") {
                adapter.openCraft()
            }
        } content: {
            NoteSurface(adapter: adapter, onCloseRequest: requestClose)
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
