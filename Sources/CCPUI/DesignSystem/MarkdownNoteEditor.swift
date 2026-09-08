// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import MarkdownEngine
import SwiftUI

/// A note edited as live-styled Markdown: the text *is* the document, and the
/// markers stay hidden — markdown here is a shortcut for formatting, and the
/// coming format UI is how styles get edited (ccp-e8df).
///
/// The one view file that names `MarkdownEngine`, so the widgets above it see
/// a CCP view and an upstream change lands here — the same rule the engine
/// adapters follow in `CCPKit`. (`CCPKit`'s sync splitter names its block AST
/// for cutting Craft blocks, and the delete monitor reads its inline AST to
/// skip hidden markers — never a view.)
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
    /// Pass-through to the engine's read-only state. Always true from the
    /// widget (ccp-t53p): the pull reconciles in the background instead of
    /// holding the caret.
    var isEditable = true
    /// How far the text stands off the editor's own frame. Roomy by default;
    /// a sticky sets its own tight pair — the card's grab padding is already
    /// the well, and doubling it would shrink the paper and grow the scroll
    /// range for nothing.
    var textInsets = TextInsets(horizontal: Space.two + Space.half, vertical: Space.two)
    /// How much empty room the engine keeps below the last line so a caret
    /// typing at the bottom of a long document isn't pinned to the edge.
    /// Sized to the viewport, so a sticky sets its own — see
    /// `stickyOverscroll`.
    var overscroll = OverscrollPolicy.default
    /// Fires with the editor's text view when it joins a window. The engine
    /// wrapper owns the view and offers no hook of its own, so this reports
    /// it per instance (see `TextViewReporter`) — the shell aiming focus
    /// without naming the engine. Same name and shape as the plain-text
    /// editor's own `onCreate` one file over.
    var onCreate: ((NSTextView) -> Void)?

    /// Body size, and the base the heading multipliers scale from.
    static let fontSize: CGFloat = 14

    /// What a sticky asks for instead of the defaults. Both live here, not at
    /// the call site, because only this file may name the engine's types.
    ///
    /// No inset: the card's 16pt paper border is already the well, and
    /// doubling it would shrink the paper for nothing.
    static let stickyInsets = TextInsets()
    /// No slack: the engine's is a fraction of the viewport, and in a note
    /// this small it starts accruing a few lines in and pushes the content
    /// past the bottom — so the scroller appears on a note whose text visibly
    /// fits. Zeroed, the content is exactly the text, and the scroll view's
    /// own autohide raises a bar only on real overflow.
    static let stickyOverscroll = OverscrollPolicy(percent: 0, maxPoints: 0, minPoints: 0)

    /// A lane-width card gives a heading nowhere to be big. H1 at 1.35× is
    /// still unmistakably a heading at 14pt, where the engine's own 2.0×
    /// would spend four lines of the card on one word.
    private static let headingMultipliers: [CGFloat] = [1.35, 1.2, 1.1, 1.0, 0.95, 0.9]

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: configuration,
            fontSize: Self.fontSize,
            documentId: documentId,
            isEditable: isEditable,
            placeholder: placeholder.map(Self.placeholderText)
        )
        .background {
            // Sibling of the wrapper's scroll view inside this editor's own
            // container, so the reporter below finds this editor's text view
            // and never a neighbour's. Nil by default: only the shell's
            // focus claimants pass one.
            if let onCreate {
                TextViewReporter(onReport: onCreate)
            }
        }
    }

    private var configuration: MarkdownEditorConfiguration {
        var configuration = MarkdownEditorConfiguration.default
        configuration.theme = Self.theme
        // Markdown is a shortcut for formatting here, not the visible text:
        // markers stay hidden even with the caret inside them (ccp-e8df).
        configuration.markers.revealMarkersOnCaret = false
        configuration.headings = HeadingStyle(fontMultipliers: Self.headingMultipliers)
        configuration.paragraph = ParagraphStyle(spacingFactor: 0.15,
                                                 lineHeightExtraSpacing: 1)
        // The well reads as inset only if the text clears its edge by a
        // visible margin on every side — roomy on purpose, roomier than card
        // chrome ever is.
        configuration.textInsets = textInsets
        configuration.overscroll = overscroll
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

/// Reports the nearest AppKit text view sharing this view's container.
///
/// SwiftUI builds `.background` content as a sibling of the modified view,
/// so the first text view met walking outward from here — excluding the
/// branch we came from at each level — is this editor's own. Fires again
/// if the view is re-created; receivers keep whatever they need weakly.
private struct TextViewReporter: NSViewRepresentable {
    let onReport: (NSTextView) -> Void

    func makeNSView(context: Context) -> TextViewReporterView {
        let view = TextViewReporterView()
        view.onReport = onReport
        return view
    }

    func updateNSView(_ nsView: TextViewReporterView, context: Context) {
        nsView.onReport = onReport
    }
}

private final class TextViewReporterView: NSView {
    /// How far up the hierarchy the search may climb. The editor's scroll
    /// view is a sibling away; anything past a few levels is a neighbour,
    /// never ours.
    private static let maxSearchDepth = 6

    var onReport: ((NSTextView) -> Void)?
    private weak var reported: NSTextView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Siblings may not be attached yet; the render finishes this tick.
        DispatchQueue.main.async { [weak self] in self?.search() }
    }

    override func layout() {
        super.layout()
        search()
    }

    private func search() {
        var child: NSView = self
        var node = superview
        var depth = 0
        while let current = node, depth < Self.maxSearchDepth {
            for subview in current.subviews where subview !== child {
                if let found = Self.textView(in: subview), found !== reported {
                    reported = found
                    onReport?(found)
                    return
                }
            }
            child = current
            node = current.superview
            depth += 1
        }
    }

    private static func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }
}
