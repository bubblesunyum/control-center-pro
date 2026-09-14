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

    /// The pad the editor and the rail agree on — one name, so the rail's bus
    /// verbs reach this editor and no other (see NoteFormatRequest).
    private var noteDocumentId: String { adapter.selectedNoteID?.uuidString ?? "notes" }

    var body: some View {
        VStack(spacing: 0) {
            MarkdownNoteEditor(
                text: Binding(get: { adapter.text }, set: { adapter.text = $0 }),
                documentId: noteDocumentId,
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

            // After the mask, so the fade dissolves the text and never the
            // rail. The host owns the rail's sampling and visibility; the
            // surface stays layout.
            .overlay(alignment: .topLeading) {
                NoteFormatRailHost(documentId: noteDocumentId, isEditable: adapter.isEditable)
            }

            // ccp-occ: the pad holds blocks Craft owns or cannot render. The
            // push never writes them and an edit restores on the next round;
            // this quiet line is the marking until the fork lands per-range
            // regions (ccp-i7g). One line for the whole pad, never per-block
            // chrome. Present only while pinned blocks are present, so the
            // card keeps its shape for every ordinary pad.
            if adapter.containsReadOnlyBlocks {
                Label("Some Craft blocks are view-only here", systemImage: "eye")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.one)
                    .padding(.top, Space.half)
                    .transition(.opacity)
                    .accessibilityLabel("Some Craft blocks are read-only")
                    .accessibilityHint("Craft content this pad can't edit. Open it in Craft to change it.")
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
    // The cloud-with-X the offline state wants; `cloud.slash` does not exist.
    case .offline: ("xmark.icloud", "Offline")
    case .unsavedChanges: ("clock", "Pending")
    case .failed: ("exclamationmark.icloud", "Failed")
    case .saved: ("cloud", "Synced")
    }
}

/// The history-adjacent dates share one UTC shape, so the sync popover's
/// lists cannot drift apart. The last-synced line is the exception: it
/// speaks the user's own clock — local zone, 12-hour, no zone label.
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

fileprivate let noteLastSyncedStyle: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.timeZone = .current
    formatter.dateFormat = "MMM d, h:mm a"
    return formatter
}()

fileprivate func noteLastSyncedText(_ date: Date) -> String {
    noteLastSyncedStyle.string(from: date)
}

/// The note's own toolbar, along its bottom edge.
private struct NoteToolbar: View {
    @Bindable var adapter: NotesAdapter
    let onDeleteSelected: () -> Void
    @State private var didCopy = false
    @State private var isSyncPopoverPresented = false

    private var isEmpty: Bool { adapter.text.isEmpty }
    private var conflicts: [ConflictRecord] {
        guard let id = adapter.selectedNoteID else { return [] }
        return adapter.conflicts(for: id)
    }

    var body: some View {
        HStack(spacing: Space.half) {
            syncStatus
            Spacer(minLength: 0)
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
            NoteToolbarButton("arrow.up.forward", label: "Open in Craft") {
                adapter.openCraftDocument()
            }
        }
        .padding(.horizontal, Space.one)
        .padding(.bottom, Space.one)
        .opacity(isEmpty && conflicts.isEmpty ? 0.5 : 1)
        // Tabbing away tears the popover down with the note — a stale true
        // would spring it uninvited beside the next one.
        .onChange(of: adapter.selectedNoteID) { isSyncPopoverPresented = false }
    }

    /// Connection/saved state for the selected doc (ccp-5fom), on the
    /// toolbar's leading edge. Small by design: an icon and a word — and the
    /// way into the sync popover, wearing the shared hover chip like the
    /// buttons beside it. Yellow while conflicts wait inside.
    private var syncStatus: some View {
        let display = notesSyncDisplay(adapter.syncStatus)
        return Button {
            isSyncPopoverPresented = true
        } label: {
            Label(display.text, systemImage: display.symbol)
                .font(.caption2)
                .padding(Space.half)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverChip(tint: conflicts.isEmpty ? nil : .yellow)
        .popover(isPresented: $isSyncPopoverPresented, arrowEdge: .bottom) {
            SyncStatusPopover(adapter: adapter, dismiss: { isSyncPopoverPresented = false })
        }
        .help("\(display.text) — show sync status and history")
        .accessibilityLabel("Sync status and history")
        .accessibilityValue(syncStatusValue(display.text))
    }

    private func syncStatusValue(_ status: String) -> String {
        guard let id = adapter.selectedNoteID,
              let date = adapter.lastSyncedAt(for: id)
        else { return "\(status), never synced" }
        return "\(status), last synced \(noteLastSyncedText(date))"
    }
}

/// The sync popover behind the toolbar's status corner: when the pad last
/// agreed with Craft, the conflicts the pulls stashed, and the way back past
/// a replacing pull or merge. One popover rather than a button per concern —
/// the status label is where the eye already goes when sync is in doubt.
///
/// Both lists collapse in place. Restoring a version snapshots the current
/// text first (as preRestore), so the menu stays safe to poke at. The copies
/// stay in Craft; dismissing forgets the record, never the pins. Recovery is
/// selecting the text out of the content pane.
private struct SyncStatusPopover: View {
    @Bindable var adapter: NotesAdapter
    let dismiss: () -> Void
    @State private var isConflictsCollapsed = false
    @State private var isHistoryCollapsed = false
    @State private var conflictSelection: UUID?

    private var padID: UUID? { adapter.selectedNoteID }
    private var records: [ConflictRecord] {
        guard let padID else { return [] }
        return adapter.conflicts(for: padID)
    }
    private var snapshots: [PadSnapshot] {
        guard let padID else { return [] }
        return adapter.snapshots(for: padID)
    }
    private var lastSynced: Date? {
        guard let padID else { return nil }
        return adapter.lastSyncedAt(for: padID)
    }

    /// The failed-push row under the last-synced line: the reason the last
    /// push failed and whether its retry is still armed. Past the final
    /// backoff nothing is scheduled, so the copy stops promising a retry.
    /// Red like the destructive rows in PopoverMenu, not a new signal.
    @ViewBuilder
    private var failureBanner: some View {
        if adapter.syncStatus == .failed {
            Text("\(adapter.lastPushErrorDescription ?? "Sync failed") — \(adapter.isPushRetryScheduled ? "retrying automatically" : "will retry on your next edit").")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, Space.one)
                .padding(.bottom, Space.two)
                .accessibilityLabel("Last push failed: \(adapter.lastPushErrorDescription ?? "sync failed")")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Last synced: \(lastSynced.map(noteLastSyncedText) ?? "Never")")
                .font(.caption)
                .foregroundStyle(.primary)
                .padding(.horizontal, Space.one)
                .padding(.top, Space.one)
                .padding(.bottom, adapter.syncStatus == .failed ? Space.half : Space.two)
            failureBanner
            if !records.isEmpty {
                WidgetSectionLabel("Conflicts", isCollapsed: $isConflictsCollapsed)
                    .padding(.horizontal, Space.one)
                // The panes stay mounted across collapse toggles: unmounting
                // and remounting a scroll view left the rebuilt one blank, so
                // collapse rides the height cap instead.
                conflictPanes
                    .frame(maxHeight: isConflictsCollapsed ? 0 : Layout.syncPopoverConflictsHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .clipped()
                    .accessibilityHidden(isConflictsCollapsed)
                if !isConflictsCollapsed {
                    conflictFooter
                }
            }
            WidgetSectionLabel("Previous versions", isCollapsed: $isHistoryCollapsed)
                .padding(.horizontal, Space.one)
            // Same stay-mounted shape as the panes above: the rows toggle
            // inside a permanent scroll view, and the demand is explicit so
            // the popover regrows on expand.
            ScrollView {
                if !isHistoryCollapsed {
                    historyRows
                }
            }
            .frame(maxHeight: isHistoryCollapsed ? 0 : Layout.syncPopoverHistoryHeight)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
            .accessibilityHidden(isHistoryCollapsed)
        }
        .padding(Space.oneHalf)
        .frame(minWidth: records.isEmpty ? Layout.shelfMenuWidth : Layout.syncPopoverWidth)
        .onAppear { conflictSelection = records.first?.id }
    }

    private var historyRows: some View {
        Group {
            if snapshots.isEmpty {
                Text("No previous versions yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.one)
                    .padding(.vertical, Space.half)
            } else if let padID {
                ForEach(snapshots) { snapshot in
                    PopoverMenuRow(systemImage: "arrow.counterclockwise.circle",
                                   title: padHistoryEntryTitle(snapshot)) {
                        adapter.restoreSnapshot(snapshot.id, for: padID)
                        dismiss()
                    }
                }
            }
        }
    }

    private var conflictPanes: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(records) { record in
                        conflictRow(record, isSelected: record.id == selectedRecord?.id)
                    }
                }
            }
            .frame(width: Layout.syncPopoverConflictListWidth)
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
        // The panes scrolled internally before; capped rather than
        // content-sized, so a long stash cannot run the popover off-screen.
        .frame(maxHeight: Layout.syncPopoverConflictsHeight)
    }

    private var selectedRecord: ConflictRecord? {
        records.first(where: { $0.id == conflictSelection }) ?? records.first
    }

    private func conflictRow(_ record: ConflictRecord, isSelected: Bool) -> some View {
        Button {
            conflictSelection = record.id
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

    private var conflictFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Copies stay in your Craft doc.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.one)
                .padding(.top, Space.half)
                .padding(.bottom, Space.quarter)
            if let selectedRecord, let padID {
                PopoverMenuRow(systemImage: "trash", title: "Forget this copy") {
                    adapter.dismissConflict(selectedRecord.id, for: padID)
                    // Stays open: the section vanishes with the last record,
                    // and the selection retargets to whatever remains.
                    conflictSelection = adapter.conflicts(for: padID).first?.id
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
