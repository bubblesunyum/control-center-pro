// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// Notes: short-lived text — meeting notes, numbers, fragments on their way
/// somewhere else — written in the panel and kept in tabs.
///
/// The tabs live in the header as a horizontal strip, in place of a title:
/// the selected tab wears a muted fill, a plain plus beside it makes a new
/// note, and a menu of hidden tabs sits on the trailing edge. The X on a tab
/// only hides it — the doc stays, and the toolbar trash is what deletes.
/// Under the header the note sits as a single inset well whose toolbar ends
/// in the way out to Craft. ``NoteSurface`` owns that well.
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
    /// Bare return starts a new block (ccp-inoq). Owned here so its lifetime
    /// is the panel's: the view graph is built once and hidden with
    /// `orderOut`, which never fires `onDisappear`, so view-bound start/stop
    /// would leave the monitor watching with the panel shut.
    private let paragraphReturn: ParagraphReturnMonitor
    /// Delete skips hidden markdown markers (ccp-e8df). Same lifetime for
    /// the same reason.
    private let markdownDelete: MarkdownDeleteMonitor

    public init() {
        self.adapter = NotesAdapter()
        self.paragraphReturn = ParagraphReturnMonitor()
        self.markdownDelete = MarkdownDeleteMonitor()
    }

    /// Test seam: widget backed by an in-memory document.
    init(document: NotesDocument) {
        self.adapter = NotesAdapter(document: document)
        self.paragraphReturn = ParagraphReturnMonitor()
        self.markdownDelete = MarkdownDeleteMonitor()
    }

    init(adapter: NotesAdapter, monitors: EventMonitors = .system) {
        self.adapter = adapter
        self.paragraphReturn = ParagraphReturnMonitor(monitors: monitors)
        self.markdownDelete = MarkdownDeleteMonitor(monitors: monitors)
    }

    public func makeView() -> some View {
        NotesContent(adapter: adapter)
    }

    public func activate() {
        adapter.activate()
        paragraphReturn.start()
        markdownDelete.start()
    }

    public func deactivate() {
        markdownDelete.stop()
        paragraphReturn.stop()
        adapter.deactivate()
    }
}

// MARK: - Content

private struct NotesContent: View {
    @Bindable var adapter: NotesAdapter
    @State private var noteToDelete: Note?

    @Environment(\.panelEditor) private var panelEditor
    @Environment(\.currentWidgetID) private var currentWidgetID

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Space.one) {
                header
                NoteSurface(adapter: adapter, onDeleteSelected: requestDeleteSelected)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Space.oneHalf)
        }
        .alert("Delete Note", isPresented: isConfirmingDelete, presenting: noteToDelete) { note in
            Button("Cancel", role: .cancel) { noteToDelete = nil }
            Button("Delete", role: .destructive) {
                _ = adapter.deleteNote(note.id)
                noteToDelete = nil
            }
        } message: { note in
            Text("Delete “\(note.name)”? Its text will be lost.")
        }
    }

    /// The header is the tab strip, not a title: the widget's icon, its tabs
    /// with the plus hugging the last one, then the hidden-tabs menu. It
    /// still publishes the header frame the panel's hold-to-edit hit-tests
    /// against, and it keeps the hold accessibility action — a custom header
    /// that drops either silently leaves the widget undraggable.
    private var header: some View {
        HStack(spacing: Space.one) {
            Image(systemName: NotesWidget.descriptor.symbolName)
                .font(.headline)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            NoteTabStrip(adapter: adapter,
                         onCloseTab: { _ = adapter.closeTab($0.id) },
                         onDeleteRequest: requestDelete)
            Spacer(minLength: 0)
            ClosedNotesMenu(adapter: adapter)
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
    /// a dialog. The trash and the tab menu share this: both delete the doc.
    private func requestDelete(_ note: Note) {
        guard adapter.canDeleteNote else { return }
        if NotesSupport.requiresDeleteConfirmation(note) {
            noteToDelete = note
        } else {
            _ = adapter.deleteNote(note.id)
        }
    }

    /// The toolbar trash deletes whatever is shown.
    private func requestDeleteSelected() {
        guard let id = adapter.selectedNoteID,
              let note = adapter.notes.first(where: { $0.id == id })
        else { return }
        requestDelete(note)
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { noteToDelete != nil }, set: { if !$0 { noteToDelete = nil } })
    }
}

/// The header's trailing edge: tabs the X hid that hold text, listed by name.
/// Choosing one brings its tab back and shows it. Empty notes never saved to
/// Craft, so they are not listed — reopening one restores nothing. Dimmed and
/// disabled while nothing restorable is hidden — a menu that opens onto
/// nothing explains itself worse.
///
/// The Files card's overflow behind its own three dots: the same
/// ``HeaderIconButton`` trigger and the same popover language
/// (``PopoverMenuSectionLabel``/``PopoverMenuRow``), so the two menus read as
/// one family.
private struct ClosedNotesMenu: View {
    @Bindable var adapter: NotesAdapter
    @State private var isMenuPresented = false

    private var isEmpty: Bool { adapter.restorableClosedNotes.isEmpty }

    var body: some View {
        HeaderIconButton(
            systemImage: "ellipsis",
            label: isEmpty ? "No closed notes" : "Closed notes"
        ) {
            isMenuPresented = true
        }
        .disabled(isEmpty)
        .opacity(isEmpty ? 0.45 : 1)
        .popover(isPresented: $isMenuPresented, arrowEdge: .top) {
            ClosedNotesPopover(adapter: adapter, dismiss: { isMenuPresented = false })
        }
    }
}

/// The restorable tabs, one icon-led row each. Dismisses on choose, like the
/// Files overflow.
private struct ClosedNotesPopover: View {
    @Bindable var adapter: NotesAdapter
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverMenuSectionLabel("Closed notes")
                .padding(.top, Space.half)
            ForEach(adapter.restorableClosedNotes) { note in
                PopoverMenuRow(systemImage: "note.text", title: note.name) {
                    _ = adapter.reopenTab(note.id)
                    dismiss()
                }
            }
        }
        .padding(.vertical, Space.half)
        .frame(minWidth: Layout.shelfMenuWidth)
    }
}
