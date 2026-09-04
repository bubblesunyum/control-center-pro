// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// Editing a ``NoteDocument`` in place: styled text, list markers, and the
/// formatting commands that go with them.
///
/// SwiftUI's own `TextEditor` takes an `AttributedString` binding, so this is
/// a thin thing on top of it rather than another `NSViewRepresentable` — it
/// inherits selection, undo, spelling, dictation and accessibility instead of
/// re-earning them. `PlainTextEditor` stays for surfaces that genuinely want
/// plain text.
///
/// The document is the truth and the text is a drawing of it, which leaves one
/// question: when to draw again. Not on every keystroke — that would move the
/// caret out from under someone mid-word. But a keystroke *can* change the
/// document's structure, because return in a list item starts another item, and
/// the new item has no bullet in front of it until the text is redrawn. So the
/// rule is structure: while the blocks stay as they were, the text is left
/// alone; the moment they don't, it is drawn again and the caret put back.
public struct NoteEditor: View {
    @Binding var document: NoteDocument

    @State private var text: AttributedString
    @State private var selection = AttributedTextSelection()
    /// The document as this view last drew it, so an edit arriving from
    /// outside can be told from the echo of one made here.
    @State private var rendered: NoteDocument

    public init(document: Binding<NoteDocument>) {
        _document = document
        _text = State(initialValue: NoteRendering.text(for: document.wrappedValue))
        _rendered = State(initialValue: document.wrappedValue)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.half) {
            editor
            if hasSelection {
                formatBar.transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.18), value: hasSelection)
    }

    private var editor: some View {
        TextEditor(text: $text, selection: $selection)
            .font(.body)
            .scrollContentBackground(.hidden)
            .onChange(of: text) { previous, updated in
                let edited = NoteRendering.document(from: updated)
                guard edited != rendered else { return }
                let restructured = !edited.hasSameStructure(as: rendered)
                rendered = edited
                document = edited
                if restructured { redraw(from: previous) }
            }
            .onChange(of: document) { _, updated in
                guard updated != rendered else { return }
                rendered = updated
                text = NoteRendering.text(for: updated)
            }
            .accessibilityLabel("Note")
    }

    /// Draw the document again and put the caret back where it was, counted in
    /// the note's own characters so a marker appearing in front of it doesn't
    /// drag it sideways.
    private func redraw(from previous: AttributedString) {
        let offset = caretOffset(in: previous) ?? caretOffset(in: text)
        let drawn = NoteRendering.text(for: rendered)
        text = drawn
        guard let offset else { return }
        let index = NoteRendering.index(atNoteOffset: offset, in: drawn)
        selection = AttributedTextSelection(range: index..<index)
    }

    private func caretOffset(in string: AttributedString) -> Int? {
        guard case .insertionPoint(let index) = selection.indices(in: string) else { return nil }
        return NoteRendering.noteOffset(of: index, in: string)
    }

    // MARK: - Commands

    /// The formatting controls, shown only while something is selected.
    ///
    /// A panel has no toolbar and no menu bar of its own to hang these off, so
    /// they live in the card — and appearing with the selection is what keeps
    /// four buttons from taking a row of a lane-width card permanently. The
    /// shortcuts bind while the bar is up, which is exactly when a mark has
    /// something to apply to.
    private var formatBar: some View {
        HStack(spacing: Space.half) {
            markButton(.bold, "Bold", "bold", .init("b", modifiers: .command))
            markButton(.italic, "Italic", "italic", .init("i", modifiers: .command))
            markButton(.strikethrough, "Strikethrough", "strikethrough",
                       .init("x", modifiers: [.command, .shift]))
            markButton(.code, "Code", "chevron.left.forwardslash.chevron.right",
                       .init("e", modifiers: .command))
        }
    }

    private var hasSelection: Bool { !selectedRanges.isEmpty }

    private func markButton(_ mark: NoteInlineStyle.Marks,
                            _ title: String,
                            _ symbol: String,
                            _ shortcut: KeyboardShortcut) -> some View {
        let isOn = isOn(mark)
        return Button { toggle(mark) } label: {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .frame(width: Layout.rowActionSize, height: Layout.rowActionSize)
                .foregroundStyle(isOn ? Color.widgetAccent : Color.labelMuted)
                .background {
                    RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
                        .fill(isOn ? Color.selectedFill : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private var selectedRanges: [Range<AttributedString.Index>] {
        switch selection.indices(in: text) {
        case .insertionPoint: []
        case .ranges(let set): Array(set.ranges)
        @unknown default: []
        }
    }

    private func isOn(_ mark: NoteInlineStyle.Marks) -> Bool {
        text.hasMark(mark, in: selectedRanges)
    }

    private func toggle(_ mark: NoteInlineStyle.Marks) {
        let ranges = selectedRanges
        guard !ranges.isEmpty else { return }
        text = text.togglingMark(mark, in: ranges)
    }
}
