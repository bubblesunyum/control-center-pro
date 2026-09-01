// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import SwiftUI

/// An AppKit text view configured as a pure plain-text surface: no smart
/// quotes or dashes, no substitutions, no rich paste, with undo. SwiftUI's
/// editor cannot switch all of that off, and its TextEditor(text:selection:)
/// would cover the caret tracking below but needs macOS 15, a version past
/// this app's floor.
///
/// Pulled from Vorssaint's UI (PlainTextEditor.swift) so the scratchpad widget
/// can offer the same plain-text surface that the floating pad does, without
/// importing the excluded UI target. Behaviour is identical; only the module
/// changed.
///
/// Name intentionally stays `PlainTextEditor` rather than `PlainTextViewRepresentable`
/// so diffs against upstream stay readable; the `*Representable` suffix rule here
/// would rename every call site with no behavioural gain.
struct PlainTextEditor: NSViewRepresentable {
    static let fontSize: CGFloat = 13
    static let lineFragmentPadding: CGFloat = 5

    @Binding var text: String
    var selectedRange: Binding<Range<Int>?>?
    var textColor: NSColor?
    var textContainerInset: NSSize?
    var onCreate: ((NSTextView) -> Void)?

    init(text: Binding<String>,
         selectedRange: Binding<Range<Int>?>? = nil,
         textColor: NSColor? = nil,
         textContainerInset: NSSize? = nil,
         onCreate: ((NSTextView) -> Void)? = nil) {
        self._text = text
        self.selectedRange = selectedRange
        self.textColor = textColor
        self.textContainerInset = textContainerInset
        self.onCreate = onCreate
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: Self.fontSize)
        textView.textContainer?.lineFragmentPadding = Self.lineFragmentPadding
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        if let textColor {
            textView.textColor = textColor
        }
        if let textContainerInset {
            textView.textContainerInset = textContainerInset
        }
        textView.string = text
        textView.delegate = context.coordinator
        onCreate?(textView)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView,
              textView.string != text,
              !textView.hasMarkedText() else { return }
        context.coordinator.isApplyingExternalText = true
        textView.string = text
        context.coordinator.isApplyingExternalText = false
        textView.undoManager?.removeAllActions()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selectedRange: selectedRange)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        private let selectedRange: Binding<Range<Int>?>?
        var isApplyingExternalText = false

        init(text: Binding<String>, selectedRange: Binding<Range<Int>?>?) {
            self.text = text
            self.selectedRange = selectedRange
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText, let textView = notification.object as? NSTextView else { return }
            let current = textView.string
            if text.wrappedValue != current { text.wrappedValue = current }
            publishSelection(of: textView, in: current)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingExternalText,
                  selectedRange != nil,
                  let textView = notification.object as? NSTextView else { return }
            publishSelection(of: textView, in: textView.string)
        }

        private func publishSelection(of textView: NSTextView, in current: String) {
            guard let selectedRange else { return }
            guard let converted = Range(textView.selectedRange(), in: current) else { return }
            selectedRange.wrappedValue =
                current.distance(from: current.startIndex, to: converted.lowerBound)
                    ..< current.distance(from: current.startIndex, to: converted.upperBound)
        }
    }
}
