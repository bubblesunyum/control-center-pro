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

            NoteToolbar(adapter: adapter, onDeleteSelected: onDeleteSelected)
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
    let onDeleteSelected: () -> Void
    @State private var didCopy = false
    @State private var isConflictsPresented = false

    private var isEmpty: Bool { adapter.text.isEmpty }
    private var conflicts: [ConflictRecord] {
        guard let id = adapter.selectedNoteID else { return [] }
        return adapter.conflicts(for: id)
    }

    var body: some View {
        HStack(spacing: Space.half) {
            NoteToolbarButton("trash", label: "Delete") { onDeleteSelected() }
                .disabled(!adapter.canDeleteNote)
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

    private static let dateStyle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d, HH:mm 'UTC'"
        return formatter
    }()

    private static func dateText(_ date: Date?) -> String {
        guard let date else { return "Unknown date" }
        return dateStyle.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverMenuSectionLabel("Conflicts")
                .padding(.top, Space.half)
            panes
            footer
        }
        .padding(.vertical, Space.half)
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
        .padding(.horizontal, Space.one)
    }

    private var selectedRecord: ConflictRecord? {
        records.first(where: { $0.id == selection }) ?? records.first
    }

    private func conflictRow(_ record: ConflictRecord, isSelected: Bool) -> some View {
        Button {
            selection = record.id
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.dateText(record.date))
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
        .accessibilityLabel("Conflict from \(Self.dateText(record.date))")
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
