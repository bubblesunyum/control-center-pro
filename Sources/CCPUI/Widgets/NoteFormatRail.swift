// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import SwiftUI

/// The notification names the pad's format rail posts and the note editor obeys.
///
/// The engine applies each request with its own marker-inserting verbs — the
/// text stays the truth, and link metadata survives — but its bus observers
/// register with `object: nil`, so a bare name would fire in every mounted
/// editor at once (Notes plus each sticky). Names are scoped per document, so
/// a tap formats the pad the rail floats beside and nothing else.
enum NoteFormatRequest {
    static func bold(for documentId: String) -> Notification.Name {
        Notification.Name("ccp.noteFormat.\(documentId).bold")
    }

    static func italic(for documentId: String) -> Notification.Name {
        Notification.Name("ccp.noteFormat.\(documentId).italic")
    }

    /// Expects `userInfo["level"]` to hold the heading level.
    static func heading(for documentId: String) -> Notification.Name {
        Notification.Name("ccp.noteFormat.\(documentId).heading")
    }

    static func bullet(for documentId: String) -> Notification.Name {
        Notification.Name("ccp.noteFormat.\(documentId).bullet")
    }
}

/// The pad's floating format rail: a VStack in the left gutter, centered on
/// the cursor line (see `clampedRailTop`).
///
/// Five marker-inserting verbs and no block menu — with live-styled Markdown
/// the marker is the command, so each button types honestly: bold wraps `**`,
/// heading prefixes `## `, and so on through the engine's own verbs. The
/// to-do toggle edits only its prefix, the one shape that keeps link metadata
/// intact (see `toggleTodo(in:)`).
///
/// Bare buttons on the well, no container fill: the rail wears the same cell
/// as the bottom toolbar, so a hover chip reads identically in both places —
/// a fill behind it would wash the chip out to nothing.
struct NoteFormatRail: View {
    /// Which pad this rail formats. Scopes the bus names; see NoteFormatRequest.
    let documentId: String
    @Environment(\.panelFocus) private var panelFocus

    /// The rail's footprint, derived from the same numbers that build it — so
    /// the clamp stays honest without measuring the view it positions.
    static let buttonSize = Layout.rowActionSize
    static let stackSpacing = Space.half
    static let edgePadding = Space.half
    static let actionCount = 5
    static var height: CGFloat {
        edgePadding * 2 + CGFloat(actionCount) * buttonSize
            + CGFloat(actionCount - 1) * stackSpacing
    }

    var body: some View {
        VStack(spacing: Self.stackSpacing) {
            NoteToolbarButton("bold", label: "Bold") {
                post(NoteFormatRequest.bold(for: documentId))
            }
            NoteToolbarButton("italic", label: "Italic") {
                post(NoteFormatRequest.italic(for: documentId))
            }
            NoteToolbarButton("textformat.size", label: "Heading") {
                applyHeading()
            }
            NoteToolbarButton("list.bullet", label: "Bulleted list") {
                post(NoteFormatRequest.bullet(for: documentId))
            }
            NoteToolbarButton("checklist", label: "To-do list") {
                applyTodo()
            }
        }
        .padding(Self.edgePadding)
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
        Self.restoreNoteFocus(to: panelFocus)
    }

    private func applyHeading() {
        guard let textView = panelFocus?.notesTextView else { return }
        let level = Self.nextHeadingLevel(after: Self.headingLevel(of: Self.selectedLine(in: textView)))
        NotificationCenter.default.post(name: NoteFormatRequest.heading(for: documentId),
                                        object: nil,
                                        userInfo: ["level": level])
        Self.restoreNoteFocus(to: panelFocus)
    }

    private func applyTodo() {
        guard let textView = panelFocus?.notesTextView else { return }
        Self.toggleTodo(in: textView)
        Self.restoreNoteFocus(to: panelFocus)
    }

    // MARK: - Geometry and line reads

    /// The rail's top edge for a caret at `caretMidY`: centered on the line,
    /// but docked near the container's ends — the bar never runs off-screen,
    /// it anchors. The bottom dock clears the toolbar fade, not just the
    /// edge, so the rail never parks over dissolving glyphs. Pure so the
    /// geometry is provable without a window.
    static func clampedRailTop(caretMidY: CGFloat, containerHeight: CGFloat,
                               railHeight: CGFloat, top: CGFloat = Space.one,
                               bottom: CGFloat = Layout.noteToolbarFadeHeight + Space.one) -> CGFloat {
        let maxTop = max(top, containerHeight - bottom - railHeight)
        return min(max(caretMidY - railHeight / 2, top), maxTop)
    }

    /// The first selected line's content without its terminator or indent —
    /// what the heading and to-do reads operate on.
    static func selectedLine(in textView: NSTextView) -> String {
        let nsText = textView.string as NSString
        let lineRange = nsText.lineRange(for: textView.selectedRange())
        let line = nsText.substring(with: lineRange)
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        return (line as NSString)
            .substring(from: indent)
            .trimmingCharacters(in: .newlines)
    }

    /// The heading level of a line, 0 for body. Mirrors the engine's own read
    /// exactly (trim, then `#` count, then a space): `##x` is body, and a
    /// four-space indent still heads — the engine normalizes it away on
    /// apply, so disagreeing here would desync the cycle from the button.
    static func headingLevel(of line: String) -> Int {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for level in 1...6 where trimmed.hasPrefix(String(repeating: "#", count: level) + " ") {
            return level
        }
        return 0
    }

    /// The rail's heading button cycles H2 → H3 → H1 → H2. The first tap
    /// always headifies and every tap visibly does something — the engine has
    /// no un-head verb, so body is backspace's job.
    static func nextHeadingLevel(after level: Int) -> Int {
        switch level {
        case 2: return 3
        case 3: return 1
        default: return 2
        }
    }

    /// The to-do toggle as a pure line transform over unindented content.
    static func todoToggledLine(_ line: String) -> String {
        if line.hasPrefix("- [ ] ") { return "- [x] " + line.dropFirst(6) }
        if line.hasPrefix("- [x] ") { return "- [ ] " + line.dropFirst(6) }
        // Some other checkbox — not ours to rewrite.
        if line.hasPrefix("- [") { return line }
        if line.hasPrefix("- ") { return "- [ ] " + line.dropFirst(2) }
        return "- [ ] " + line
    }

    /// Toggles the first selected line's to-do prefix, editing only the
    /// prefix characters. Rewriting the line wholesale would strip
    /// `.wikiLinkID` from anything on it — the only copy of a link's UUID
    /// once its range shifts — so every branch here is an insertion or a
    /// same-width swap at the line head, indent preserved. The engine's own
    /// blockquote toggle keeps the same rule.
    static func toggleTodo(in textView: NSTextView) {
        let nsText = textView.string as NSString
        let selection = textView.selectedRange()
        let lineRange = nsText.lineRange(for: selection)
        let line = nsText.substring(with: lineRange)
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        let head = lineRange.location + indent

        func edit(_ range: NSRange, with string: String, caret: Int) {
            guard textView.shouldChangeText(in: range, replacementString: string) else { return }
            textView.replaceCharacters(in: range, with: string)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: caret, length: 0))
        }

        let content = (line as NSString).substring(from: indent).trimmingCharacters(in: .newlines)
        if content.hasPrefix("- [ ] ") || content.hasPrefix("- [x] ") {
            // Same-width swap of the checkbox: `- [ ]` is `-`, ` `, `[`,
            // ` `, `]`, ` ` — the mark lives at head + 3. Nothing after it
            // shifts, so the caret stays.
            edit(NSRange(location: head + 3, length: 1),
                 with: content.hasPrefix("- [ ] ") ? "x" : " ",
                 caret: selection.location)
        } else if content.hasPrefix("- [") {
            return
        } else if content.hasPrefix("- ") {
            let at = head + 2
            edit(NSRange(location: at, length: 0), with: "[ ] ",
                 caret: selection.location >= at ? selection.location + 4 : selection.location)
        } else {
            edit(NSRange(location: head, length: 0), with: "- [ ] ",
                 caret: selection.location >= head ? selection.location + 6 : selection.location)
        }
    }

    /// Puts the caret back in the pad after a rail tap. Rail buttons refuse
    /// key focus like any button, but a tap can still move first responder —
    /// without the reclaim the next keystroke lands nowhere.
    @MainActor
    static func restoreNoteFocus(to panelFocus: PanelFocus?) {
        guard let textView = panelFocus?.notesTextView,
              let window = textView.window,
              window.firstResponder !== textView else { return }
        window.makeFirstResponder(textView)
    }
}

/// Owns the rail's caret sampling and visibility, so the surface stays
/// layout-only: one overlay line, nothing sampled in the card.
struct NoteFormatRailHost: View {
    let documentId: String
    let isEditable: Bool
    @Environment(\.panelFocus) private var panelFocus
    @Environment(\.isPanelEditing) private var isPanelEditing
    @State private var monitor = RailCaretMonitor()
    @State private var caretY: CGFloat?
    @State private var containerHeight: CGFloat = 0

    /// The rail shows on an editable pad outside edit mode, once the caret
    /// reports — never over a drag, a gallery, or a background pull.
    private var isVisible: Bool {
        isEditable && !isPanelEditing && caretY != nil
    }

    /// Identity of the editor the rail tracks, so a remade text view
    /// re-anchors instead of following a torn-down one.
    private var textViewID: ObjectIdentifier? {
        panelFocus?.notesTextView.map(ObjectIdentifier.init)
    }

    var body: some View {
        // Siblings, deliberately: `allowsHitTesting(false)` excludes the
        // whole subtree it sits on, and no descendant can opt back in — so
        // the measuring reader carries it alone over bare clear, and the
        // rail keeps default hit testing.
        ZStack(alignment: .topLeading) {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { containerHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, height in
                        containerHeight = height
                    }
            }
            .allowsHitTesting(false)
            if isVisible, let caretY, containerHeight > 0 {
                NoteFormatRail(documentId: documentId)
                    .offset(y: NoteFormatRail.clampedRailTop(
                        caretMidY: caretY,
                        containerHeight: containerHeight,
                        railHeight: NoteFormatRail.height))
                    // Gutter math: 4pt from the well plus the 30pt rail
                    // meets the 34pt text inset exactly — no glyph column
                    // under the buttons, and no well gap wasted.
                    .padding(.leading, Space.half)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isVisible)
        .onChange(of: textViewID, initial: true) {
            monitor.track(panelFocus?.notesTextView)
        }
        .onAppear {
            monitor.onUpdate = { caretY = $0 }
            // Re-track after the callback lands: the initial change above
            // may refresh first and its value would fall on no listener.
            monitor.track(panelFocus?.notesTextView)
        }
        .onDisappear {
            monitor.untrack()
        }
    }
}
