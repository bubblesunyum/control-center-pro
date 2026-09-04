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
    @FocusState private var isEditing: Bool

    public init(document: Binding<NoteDocument>) {
        _document = document
        _text = State(initialValue: NoteRendering.text(for: document.wrappedValue))
        _rendered = State(initialValue: document.wrappedValue)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.half) {
            editor
            if isEditing {
                formatBar.transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.18), value: isEditing)
    }

    private var editor: some View {
        TextEditor(text: $text, selection: $selection)
            .font(.body)
            .scrollContentBackground(.hidden)
            .focused($isEditing)
            .onChange(of: text) { previous, updated in
                let edited = NoteRendering.document(from: updated)
                guard edited != rendered else { return }
                if let position = caretBlock(in: updated, of: edited),
                   let formatted = edited.autoformatted(at: position) {
                    commit(formatted, caretAt: NoteRendering.noteOffset(ofBlockAt: position,
                                                                       in: formatted))
                    return
                }
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

    // MARK: - Redrawing

    /// Draw the document again and put the caret back where it was, counted in
    /// the note's own characters so a marker appearing in front of it doesn't
    /// drag it sideways.
    private func redraw(from previous: AttributedString) {
        let offsets = selectedOffsets(in: previous) ?? selectedOffsets(in: text)
        text = NoteRendering.text(for: rendered)
        restore(offsets)
    }

    /// Take `updated` as the note, draw it, and leave the caret at a known
    /// place in it — where a command has moved the text out from under the
    /// selection rather than merely restyled it.
    private func commit(_ updated: NoteDocument, caretAt offset: Int) {
        rendered = updated
        document = updated
        text = NoteRendering.text(for: updated)
        restore(offset...offset)
    }

    /// Apply a change to the note itself and draw the result, keeping whatever
    /// was selected selected — a heading is still the same characters, so a
    /// block command should leave the user's selection where they made it.
    private func apply(_ change: (NoteDocument) -> NoteDocument) {
        let updated = change(rendered)
        guard updated != rendered else { return }
        let offsets = selectedOffsets(in: text)
        rendered = updated
        document = updated
        text = NoteRendering.text(for: updated)
        restore(offsets)
    }

    private func restore(_ offsets: ClosedRange<Int>?) {
        guard let offsets else { return }
        let lower = NoteRendering.index(atNoteOffset: offsets.lowerBound, in: text)
        let upper = NoteRendering.index(atNoteOffset: offsets.upperBound, in: text)
        selection = AttributedTextSelection(range: lower..<upper)
    }

    /// Which block of `document` the caret is in, read off `string` — what
    /// autoformatting needs so it only ever converts the line being typed on.
    private func caretBlock(in string: AttributedString, of document: NoteDocument) -> Int? {
        selectedOffsets(in: string).map {
            NoteRendering.blockPosition(atNoteOffset: $0.upperBound, in: document)
        }
    }

    /// Where the selection sits counted in the note's own characters. A caret
    /// is the empty range, which is what makes one restore serve both.
    private func selectedOffsets(in string: AttributedString) -> ClosedRange<Int>? {
        let indices: [AttributedString.Index] = switch selection.indices(in: string) {
        case .insertionPoint(let index): [index]
        case .ranges(let set): [set.ranges.first?.lowerBound, set.ranges.last?.upperBound]
            .compactMap { $0 }
        @unknown default: []
        }
        let offsets = indices.map { NoteRendering.noteOffset(of: $0, in: string) }
        guard let lowest = offsets.min(), let highest = offsets.max() else { return nil }
        return lowest...highest
    }

    // MARK: - Commands

    /// The formatting controls, shown while the note has the keyboard.
    ///
    /// A panel has no toolbar and no menu bar of its own to hang these off, so
    /// they live in the card — and appearing with the focus is what keeps them
    /// from taking a row of a lane-width card permanently. Focus rather than
    /// selection because a block command works from a caret alone: asking
    /// someone to select their heading before they can make it one is the
    /// wrong shape.
    private var formatBar: some View {
        HStack(spacing: Space.half) {
            blockMenu
            Divider().frame(height: Layout.rowActionSize / 2)
            markButton(.bold, "Bold", "bold", .init("b", modifiers: .command))
            markButton(.italic, "Italic", "italic", .init("i", modifiers: .command))
            markButton(.strikethrough, "Strikethrough", "strikethrough",
                       .init("x", modifiers: [.command, .shift]))
            markButton(.code, "Code", "chevron.left.forwardslash.chevron.right",
                       .init("e", modifiers: .command))
            Spacer(minLength: 0)
            indentButton(by: -1, "Outdent", "decrease.indent", .init("[", modifiers: .command))
            indentButton(by: 1, "Indent", "increase.indent", .init("]", modifiers: .command))
        }
    }

    /// What kind of block the caret is in, offered by name. A menu rather than
    /// a row of buttons: nine kinds would eat the card, and a menu shows the
    /// one you are in without spending any width on the eight you are not.
    private var blockMenu: some View {
        Menu {
            Section("Text") { blockItems(NoteBlockCommand.textStyles) }
            Section("Lists") { blockItems(NoteBlockCommand.lists) }
            Section { blockItems(NoteBlockCommand.blocks) }
        } label: {
            Image(systemName: currentBlock?.symbol ?? NoteBlockCommand.paragraph.symbol)
                .font(.caption.weight(.semibold))
                .frame(width: Layout.rowActionSize, height: Layout.rowActionSize)
                .foregroundStyle(Color.labelMuted)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Block Kind")
        .accessibilityLabel("Block kind")
        .accessibilityValue(currentBlock?.title ?? NoteBlockCommand.paragraph.title)
    }

    private func blockItems(_ commands: [NoteBlockCommand]) -> some View {
        ForEach(commands) { command in
            Toggle(isOn: Binding(
                get: { rendered.blocks(at: selectedBlocks, allAre: command.kind) },
                set: { _ in apply { $0.togglingKind(command.kind, forBlocksAt: selectedBlocks) } }
            )) {
                Label(command.title, systemImage: command.symbol)
            }
        }
    }

    private var currentBlock: NoteBlockCommand? {
        guard let position = selectedBlocks.first, rendered.blocks.indices.contains(position) else {
            return nil
        }
        return NoteBlockCommand.matching(rendered.blocks[position].kind)
    }

    /// The blocks the selection touches — one for a caret, and every block a
    /// range reaches into, so a command over several paragraphs lands on all
    /// of them.
    private var selectedBlocks: Range<Int> {
        guard let offsets = selectedOffsets(in: text) else { return 0..<0 }
        let first = NoteRendering.blockPosition(atNoteOffset: offsets.lowerBound, in: rendered)
        let last = NoteRendering.blockPosition(atNoteOffset: offsets.upperBound, in: rendered)
        return first..<(last + 1)
    }

    private func indentButton(by steps: Int,
                              _ title: String,
                              _ symbol: String,
                              _ shortcut: KeyboardShortcut) -> some View {
        barButton(symbol, title, isOn: nil, shortcut: shortcut) {
            apply { $0.indentingBlocks(at: selectedBlocks, by: steps) }
        }
        .disabled(!canIndent(by: steps))
    }

    private func canIndent(by steps: Int) -> Bool {
        guard let indents = rendered.indentRange(atBlocks: selectedBlocks) else { return false }
        return steps < 0
            ? indents.lowerBound > 0
            : indents.upperBound < NoteBlock.maximumIndent
    }

    private func markButton(_ mark: NoteInlineStyle.Marks,
                            _ title: String,
                            _ symbol: String,
                            _ shortcut: KeyboardShortcut) -> some View {
        barButton(symbol, title, isOn: text.hasMark(mark, in: selectedRanges), shortcut: shortcut) {
            toggle(mark)
        }
        .disabled(selectedRanges.isEmpty)
    }

    /// One control in the bar. `isOn` is nil for the ones that do something
    /// rather than turn something on — an indent has no state to announce, and
    /// saying "Off" would promise it did.
    private func barButton(_ symbol: String,
                           _ title: String,
                           isOn: Bool?,
                           shortcut: KeyboardShortcut,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .frame(width: Layout.rowActionSize, height: Layout.rowActionSize)
                .foregroundStyle(isOn == true ? Color.widgetAccent : Color.labelMuted)
                .background {
                    RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
                        .fill(isOn == true ? Color.selectedFill : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.map { $0 ? "On" : "Off" } ?? "")
    }

    private var selectedRanges: [Range<AttributedString.Index>] {
        switch selection.indices(in: text) {
        case .insertionPoint: []
        case .ranges(let set): Array(set.ranges)
        @unknown default: []
        }
    }

    private func toggle(_ mark: NoteInlineStyle.Marks) {
        let ranges = selectedRanges
        guard !ranges.isEmpty else { return }
        text = text.togglingMark(mark, in: ranges)
    }
}
