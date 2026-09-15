// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

/// The pad's floating format rail: a VStack in the left gutter, centered on
/// the cursor line (see `clampedRailTop`).
///
/// Five of the editor's own commands and no block menu: bold and italic
/// toggle their marks, heading cycles the level, and the list buttons toggle
/// the caret's block in and out of a list.
///
/// Bare buttons on the well, no container fill: the rail wears the same cell
/// as the bottom toolbar, so a hover chip reads identically in both places —
/// a fill behind it would wash the chip out to nothing.
struct NoteFormatRail: View {
    /// Which pad this rail formats.
    let documentId: String
    let controller: NoteEditorController

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
            NoteToolbarButton("bold", label: "Bold") { run("toggleBold") }
            NoteToolbarButton("italic", label: "Italic") { run("toggleItalic") }
            NoteToolbarButton("textformat.size", label: "Heading") {
                let level = Self.nextHeadingLevel(after: controller.caret?.headingLevel ?? 0)
                run("setHeading", ["level": level])
            }
            NoteToolbarButton("list.bullet", label: "Bulleted list") { run("toggleBulletList") }
            NoteToolbarButton("checklist", label: "To-do list") { run("toggleTaskList") }
        }
        .padding(Self.edgePadding)
    }

    private func run(_ command: String, _ argument: [String: Any]? = nil) {
        controller.run(command, argument, documentId: documentId)
    }

    // MARK: - Geometry

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

    /// The rail's heading button cycles H2 → H3 → H1 → H2. The first tap
    /// always headifies and every tap visibly does something; body is
    /// backspace's job.
    static func nextHeadingLevel(after level: Int) -> Int {
        switch level {
        case 2: return 3
        case 3: return 1
        default: return 2
        }
    }
}

/// Shows the rail beside the caret while the pad holds it, so the surface
/// stays layout-only: one overlay line, nothing sampled in the card.
struct NoteFormatRailHost: View {
    let documentId: String
    let isEditable: Bool
    var controller: NoteEditorController = .notes
    @Environment(\.isPanelEditing) private var isPanelEditing
    @State private var containerHeight: CGFloat = 0

    /// The caret's line, while this pad is focused.
    private var caretY: CGFloat? {
        guard let caret = controller.caret, caret.documentId == documentId else { return nil }
        return caret.midY
    }

    /// The rail shows on an editable pad outside edit mode, once the caret
    /// reports — never over a drag, a gallery, or a background pull.
    private var isVisible: Bool {
        isEditable && !isPanelEditing && caretY != nil
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
                NoteFormatRail(documentId: documentId, controller: controller)
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
    }
}
