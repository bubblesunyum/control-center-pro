// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import MarkdownEngine
import SwiftUI

/// A note edited as live-styled Markdown: the text *is* the document, and the
/// markers hide themselves until the caret lands on one.
///
/// The one file that names `MarkdownEngine`, so the widgets above it see a
/// CCP view and an upstream change lands here — the same rule the engine
/// adapters follow in `CCPKit`.
///
/// A ~148pt card is not the full-window notes app the engine was written for,
/// so its defaults are retuned rather than accepted: the heading ramp is
/// flattened, paragraph spacing tightened, and the reading column left off.
struct MarkdownNoteEditor: View {
    @Binding var text: String

    /// Which pad this is. The engine scopes undo history and scroll offset by
    /// it, so pads must not share one.
    let documentId: String
    var placeholder: String?

    /// Body size, and the base the heading multipliers scale from.
    static let fontSize: CGFloat = 13

    /// A lane-width card gives a heading nowhere to be big. H1 at 1.35× is
    /// still unmistakably a heading at 13pt, where the engine's own 2.0×
    /// would spend four lines of the card on one word.
    private static let headingMultipliers: [CGFloat] = [1.35, 1.2, 1.1, 1.0, 0.95, 0.9]

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: Self.configuration,
            fontSize: Self.fontSize,
            documentId: documentId,
            placeholder: placeholder.map(Self.placeholderText)
        )
    }

    private static var configuration: MarkdownEditorConfiguration {
        var configuration = MarkdownEditorConfiguration.default
        configuration.theme = theme
        configuration.headings = HeadingStyle(fontMultipliers: headingMultipliers)
        configuration.paragraph = ParagraphStyle(spacingFactor: 0.15,
                                                 lineHeightExtraSpacing: 1)
        configuration.textInsets = TextInsets(horizontal: Space.one,
                                              vertical: Space.half)
        return configuration
    }

    private static var theme: MarkdownEditorTheme {
        var theme = MarkdownEditorTheme.default
        theme.bodyText = .labelColor
        theme.mutedText = .secondaryLabelColor
        theme.headingMarker = .tertiaryLabelColor
        return theme
    }

    private static func placeholderText(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }
}
