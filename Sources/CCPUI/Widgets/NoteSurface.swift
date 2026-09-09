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
    /// Delete whatever is shown, through the widget's confirmation.
    let onDeleteSelected: () -> Void
    @State private var isDropTargeted = false
    @Environment(\.panelFocus) private var panelFocus

    var body: some View {
        VStack(spacing: 0) {
            MarkdownNoteEditor(
                text: Binding(get: { adapter.text }, set: { adapter.text = $0 }),
                documentId: adapter.selectedNoteID?.uuidString ?? "notes",
                placeholder: "Write something…",
                isEditable: adapter.isEditable,
                // The panel's default keystrokes: the window falls back here
                // on a fresh open, and the controller re-asserts it on every
                // open after (see `PanelFocus`).
                onCreate: { [weak panelFocus, adapter] textView in
                    panelFocus?.notesTextView = textView
                    if textView.isEditable {
                        textView.window?.initialFirstResponder = textView
                    }
                    // The mount a replacing pull arrived before: the delivery
                    // stayed pending for exactly this.
                    Self.clearStaleUndoIfPending(adapter: adapter, panelFocus: panelFocus)
                }
            )
            // Optimistic editing (ccp-t53p): the pull reconciles around
            // keystrokes in the background, so the editor never dims or
            // holds the caret while it proves.
            // The card takes whatever height its lane gives it, and the editor
            // takes all of that: pinned to its floor instead, the note grows a
            // strip of container below the text that looks editable and
            // swallows the click.
            .frame(minHeight: Layout.noteEditorHeight, maxHeight: .infinity)
            .accessibilityLabel("Note text")
            .accessibilityHint("Editable Markdown")
            // A pull (or restore) that replaces the visible pad wholesale
            // strands the editor's undo stack at stale ranges — cmd-Z would
            // walk into pre-pull text and push it as if typed. The snapshots
            // keep the way back, so the stack drops.
            .onChange(of: adapter.padsPendingUndoClear) {
                Self.clearStaleUndoIfPending(adapter: adapter, panelFocus: panelFocus)
            }
            .onChange(of: adapter.selectedNoteID) {
                // Clear before acknowledging: a visible pad replaced just
                // ahead of a switch away and back still holds its flag, and
                // the engine's switch-back baseline is already post-replace
                // — acknowledging first would drop the flag the clear checks.
                Self.clearStaleUndoIfPending(adapter: adapter, panelFocus: panelFocus)
                // Then acknowledge what the engine owns: a background pad's
                // stack is invalidated on switch-back, so a surviving flag
                // would only clear fresh keystrokes on a later delivery.
                if let id = adapter.selectedNoteID { adapter.acknowledgeUndoClear(for: id) }
            }
            // The toolbar's fade: the last lines dissolve into the toolbar
            // instead of clipping hard. A mask on the content, not a scrim
            // on the backdrop — the well is near-black, so darkening it
            // further reads as nothing; fading the glyphs is what reads.
            .mask {
                VStack(spacing: 0) {
                    Color.white
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: Layout.noteToolbarFadeHeight)
                }
            }

            NoteToolbar(adapter: adapter, onDeleteSelected: onDeleteSelected)
        }
        .frame(maxWidth: .infinity)
        .noteInsetChrome()
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: Stroke.hairline)
            }
        }
        // Clipboard rows, Finder files and browser text all land here; images
        // have no text form and spring back unaccepted.
        .onDrop(of: [.plainText, .text, .rtf, .html, .fileURL, .url], isTargeted: $isDropTargeted) { providers in
            adapter.acceptDrop(providers: providers)
        }
    }
}

/// Drop the visible editor's undo stack when its pad's text was replaced
/// wholesale underneath it. Needs the text view alive — the reporter mounts
/// it a runloop after the editor, so an early delivery stays pending for
/// the next check instead of missing permanently.
extension NoteSurface {
    fileprivate static func clearStaleUndoIfPending(adapter: NotesAdapter, panelFocus: PanelFocus?) {
        guard let id = adapter.selectedNoteID,
              adapter.padsPendingUndoClear.contains(id),
              let textView = panelFocus?.notesTextView
        else { return }
        textView.undoManager?.removeAllActions()
        adapter.acknowledgeUndoClear(for: id)
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

/// The toolbar status and the editor hint share one mapping, so the symbol
/// and the words cannot drift apart.
fileprivate func notesSyncDisplay(_ status: NotesAdapter.SyncStatus) -> (symbol: String, text: String) {
    switch status {
    case .localOnly: ("internaldrive", "Local")
    case .syncing: ("arrow.triangle.2.circlepath", "Syncing")
    // The cloud-with-X the error state wants; `cloud.slash` does not exist.
    case .offline: ("xmark.icloud", "Error")
    case .unsavedChanges: ("clock", "Unsaved")
    case .saved: ("cloud", "Synced")
    }
}

/// The history-adjacent dates share one UTC shape, so the conflicts popover
/// and the history menu cannot drift apart.
fileprivate let noteHistoryDateStyle: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "MMM d, HH:mm 'UTC'"
    return formatter
}()

fileprivate func noteHistoryDateText(_ date: Date?) -> String {
    guard let date else { return "Unknown date" }
    return noteHistoryDateStyle.string(from: date)
}

/// The note's own toolbar, along its bottom edge.
private struct NoteToolbar: View {
    @Bindable var adapter: NotesAdapter
    let onDeleteSelected: () -> Void
    @State private var didCopy = false
    @State private var isConflictsPresented = false

    private var isEmpty: Bool { adapter.text.isEmpty }
    private var conflicts: [ConflictRecord] {
        guard let id = adapter.selectedNoteID else { return [] }
        return adapter.conflicts(for: id)
    }
    private var snapshots: [PadSnapshot] {
        guard let id = adapter.selectedNoteID else { return [] }
        return adapter.snapshots(for: id)
    }

    var body: some View {
        HStack(spacing: Space.half) {
            syncStatus
            Spacer(minLength: 0)
            if !conflicts.isEmpty {
                NoteToolbarButton("exclamationmark.triangle.fill", label: "Conflicts",
                                  tint: .yellow) {
                    isConflictsPresented = true
                }
                // The button leaves the hierarchy with the last conflict, and
                // a stale true would spring the popover on the NEXT conflict
                // uninvited — so the flag resets everywhere the list empties.
                .popover(isPresented: $isConflictsPresented, arrowEdge: .top) {
                    ConflictsPopover(adapter: adapter, isPresented: $isConflictsPresented)
                }
            }
            // The pad's way back past a replacing pull or merge: restoring
            // snapshots the current text first, so the menu is safe to poke
            // at. Beside conflicts, the same family — and only while there
            // is anything to go back to.
            if let padID = adapter.selectedNoteID, !snapshots.isEmpty {
                Menu {
                    ForEach(snapshots) { snapshot in
                        Button(padHistoryEntryTitle(snapshot)) {
                            adapter.restoreSnapshot(snapshot.id, for: padID)
                        }
                    }
                } label: {
                    NoteToolbarIcon(symbol: "arrow.counterclockwise.circle")
                }
                .accessibilityLabel("Pad history")
                .help("Pad history")
            }
            NoteToolbarButton("trash", label: "Delete") { onDeleteSelected() }
                .disabled(!adapter.canDeleteNote)
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
            .disabled(isEmpty)
            NoteToolbarButton("square.and.arrow.down", label: "Export") { adapter.exportText() }
                .disabled(isEmpty)
            NoteToolbarButton("arrow.up.forward", label: "Open in Craft") {
                adapter.openCraftDocument()
            }
        }
        .padding(.horizontal, Space.one)
        .padding(.bottom, Space.one)
        .opacity(isEmpty && conflicts.isEmpty ? 0.5 : 1)
        // Tabbing away tears the button (and its popover) down with a stale
        // true — the next conflict would otherwise open uninvited.
        .onChange(of: adapter.selectedNoteID) { isConflictsPresented = false }
    }

    /// Connection/saved state for the selected doc (ccp-5fom), on the
    /// toolbar's leading edge where the trash used to sit. Small by design:
    /// an icon and a word, secondary all the way.
    private var syncStatus: some View {
        let display = notesSyncDisplay(adapter.syncStatus)
        return Label(display.text, systemImage: display.symbol)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help(display.text)
    }
}

/// What the last syncs set aside: each conflict the pull stashed into Craft
/// instead of overwriting, newest first. The popover speaks the Files
/// overflow menu's language — section label, hover rows — with a list pane
/// beside a content pane.
///
/// The copies stay in Craft; dismissing forgets the record, never the pins.
/// Recovery is selecting the text out of the content pane.
private struct ConflictsPopover: View {
    @Bindable var adapter: NotesAdapter
    @Binding var isPresented: Bool
    @State private var selection: UUID?

    private var padID: UUID? { adapter.selectedNoteID }
    private var records: [ConflictRecord] {
        guard let padID else { return [] }
        return adapter.conflicts(for: padID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverMenuSectionLabel("Conflicts")
            panes
            footer
        }
        .padding(Space.oneHalf)
        .frame(minWidth: Layout.conflictsPopoverWidth,
               minHeight: Layout.conflictsPopoverHeight)
        .onAppear { selection = records.first?.id }
    }

    private var panes: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(records) { record in
                        conflictRow(record, isSelected: record.id == selectedRecord?.id)
                    }
                }
            }
            .frame(width: Layout.conflictsListWidth)
            Divider().padding(.horizontal, Space.half)
            if let selectedRecord {
                ScrollView {
                    Text(selectedRecord.slices.joined(separator: "\n\n"))
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Space.half)
                }
            }
        }
    }

    private var selectedRecord: ConflictRecord? {
        records.first(where: { $0.id == selection }) ?? records.first
    }

    private func conflictRow(_ record: ConflictRecord, isSelected: Bool) -> some View {
        Button {
            selection = record.id
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(noteHistoryDateText(record.date))
                    .font(.caption.weight(.semibold))
                Text("\(record.slices.count) lines")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.one)
            .padding(.vertical, Space.half)
            .frame(maxWidth: .infinity, minHeight: Layout.shelfMenuRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .buttonStyle(PopoverMenuRowStyle(isSelected: isSelected))
        .accessibilityLabel("Conflict from \(noteHistoryDateText(record.date))")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, Space.half)
            Text("Copies stay in your Craft doc.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.one)
                .padding(.bottom, Space.quarter)
            if let selectedRecord, let padID {
                PopoverMenuRow(systemImage: "trash", title: "Forget this copy") {
                    adapter.dismissConflict(selectedRecord.id, for: padID)
                    // The last forget empties the list and tears this popover
                    // down; a stale true would spring it on the next conflict.
                    selection = adapter.conflicts(for: padID).first?.id
                    if adapter.conflicts(for: padID).isEmpty { isPresented = false }
                }
            }
        }
    }
}

/// One history entry's title: the reason beside the date, so restoring
/// reads as a choice rather than a guess. A plain function — the shared
/// date helper already models the formatting, no namespace needed.
fileprivate func padHistoryEntryTitle(_ snapshot: PadSnapshot) -> String {
    let reason: String
    switch snapshot.reason {
    case .pull: reason = "Synced from Craft"
    case .conflict: reason = "Conflict with Craft"
    case .preRestore: reason = "Before restore"
    }
    return "\(reason) — \(noteHistoryDateText(snapshot.date))"
}

/// The toolbar's icon cell: caption symbol in a row-action frame, wearing
/// the hover chip. Shared by the buttons and the history menu label, which
/// needs its own labeled view rather than a Button.
private struct NoteToolbarIcon: View {
    let symbol: String
    let tint: Color?
    @State private var isHovered = false

    // Explicit: a `let` with a default drops out of the memberwise init
    // beside a property wrapper, so the default lives here instead.
    init(symbol: String, tint: Color? = nil) {
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.caption)
            .frame(width: Layout.rowActionSize, height: Layout.rowActionSize)
            .contentShape(Rectangle())
            .foregroundStyle(tint ?? (isHovered ? Color.primary : Color.secondary))
            .background {
                RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
                    .fill(isHovered ? Color.controlFill : Color.clear)
            }
            .onHover { isHovered = $0 }
    }
}

/// One button in the note's bottom toolbar, wearing the same hover chip as
/// the header's plus — one step brighter, over a muted fill.
private struct NoteToolbarButton: View {
    private let symbol: String
    private let label: String
    private let tint: Color?
    private let action: () -> Void

    init(_ symbol: String, label: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            NoteToolbarIcon(symbol: symbol, tint: tint)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
