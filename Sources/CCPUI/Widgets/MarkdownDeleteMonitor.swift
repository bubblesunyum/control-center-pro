// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import MarkdownEngine

/// Delete and forward-delete skip hidden markdown markers. With
/// `revealMarkersOnCaret` off the markers stay in the text but read as
/// zero-width, so a stock backspace would eat an invisible `*` instead of
/// the letter beside it — the confusion this exists to remove.
///
/// Upstream is untouched; this watches from outside the text view like
/// `ParagraphReturnMonitor` and reroutes through `insertText`, so undo
/// reads as typing. Every decision is read off the engine's own parse
/// (`DocumentAST`), so the monitor and the styling can never disagree
/// about what a marker is.
///
/// Three rules:
/// - Beside a hidden closer/opener the delete lands on the neighbouring
///   content character, never a marker.
/// - Emptying a span's content takes its markers with it in the same
///   keystroke — no invisible `****` left behind for a second backspace.
/// - At the content start of a converted heading/list/quote line, backspace
///   removes the hidden prefix AND the newline in one step, joining up to
///   the previous line as plain text — as if the prefix was never typed.
///   An empty converted line un-converts in place instead, keeping its line.
///
/// Anything else — mid-content deletes, selections that aren't exactly one
/// span's content, option/command deletes — passes through untouched.
///
/// The pure decision functions are deliberately static and engine-shaped so
/// they can move next to the Craft splitter in CCPKit later (ccp-87ny); the
/// lifecycle/start/stop shape is shared with the return monitor (ccp-ipvl).
@MainActor
final class MarkdownDeleteMonitor {
    private let monitors: EventMonitors
    /// The key window's first responder while it is a text view. Same
    /// scoping as the return monitor: the only real `NSTextView` in the
    /// app is the pad editor.
    private let editor: () -> NSTextView?
    private var monitor: Any?

    init(monitors: EventMonitors = .system,
         editor: @escaping () -> NSTextView? = { NSApp.keyWindow?.firstResponder as? NSTextView }) {
        self.monitors = monitors
        self.editor = editor
    }

    var isWatching: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        // No `?? event` fallback: optional chaining flattens, so a
        // swallowed nil would read as a vanished self and every rerouted
        // delete would ALSO reach the editor as a second deletion.
        monitor = monitors.addLocal(.keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        guard let monitor else { return }
        monitors.remove(monitor)
        self.monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard Self.isBareDelete(event),
              let textView = editor(),
              !textView.isFieldEditor,
              textView.isEditable,
              !textView.hasMarkedText(),
              NSApp?.modalWindow == nil
        else { return event }
        let string = textView.string as NSString
        let range = textView.selectedRange()
        guard range.location != NSNotFound,
              NSMaxRange(range) <= string.length,
              let deletion = Self.deletionRange(string: string, range: range,
                                               forward: event.keyCode == Self.forwardDeleteKeyCode)
        else { return event }
        // An empty range is a swallowed no-op (nothing visible to delete);
        // anything else replaces with "" so undo restores it whole.
        textView.insertText("", replacementRange: deletion)
        return nil
    }

    /// A bare backspace or forward delete. Shift is not a combining
    /// modifier here (shift+backspace still deletes backward); command,
    /// control and option keep their upstream word/line behaviour and pass
    /// through. CapsLock and the numeric-pad/function flags must not veto
    /// (forward delete arrives with fn held).
    private static func isBareDelete(_ event: NSEvent) -> Bool {
        (event.keyCode == Self.deleteKeyCode || event.keyCode == Self.forwardDeleteKeyCode)
            && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    private static let deleteKeyCode: UInt16 = 51
    private static let forwardDeleteKeyCode: UInt16 = 117

    /// The range to replace with `""` (possibly empty: swallow), or nil to
    /// let AppKit handle the key.
    static func deletionRange(string: NSString, range: NSRange, forward: Bool) -> NSRange? {
        let blocks = DocumentAST.parse(string as String)
        if range.length == 0 {
            let caret = range.location
            let prefixes = blockPrefixes(string: string, blocks: blocks)
            if !forward,
               let join = blockPrefixJoin(string: string, prefixes: prefixes, caret: caret) {
                return join
            }
            if forward,
               let strip = blockPrefixStrip(prefixes: prefixes, caret: caret) {
                return strip
            }
            let spans = inlineSpans(in: blocks)
            return forward
                ? forwardDeleteRange(string: string, spans: spans, caret: caret)
                : backspaceRange(string: string, spans: spans, prefixes: prefixes, caret: caret)
        }
        // A selection that is exactly one span's content takes the whole
        // span — selecting the `d` in `**d**` must not leave `****` behind.
        for span in inlineSpans(in: blocks) where span.content == range {
            return span.range
        }
        return nil
    }

    // MARK: - Inline spans

    /// One styled run with its hidden edges broken out. `content` is the
    /// visible text; `open`/`close` are the hidden markers around it (either
    /// may be empty, e.g. an escape's trailing edge).
    struct Span {
        let range: NSRange
        let open: NSRange
        let content: NSRange
        let close: NSRange
    }

    /// Every inline run the engine styles with hideable markers. Image alt
    /// text, embeds and escapes read through the same hidden-marker shrink
    /// as emphasis, so they ride along; inline LaTeX does NOT (with CCP's
    /// services its `$` markers stay full-size visible, so AppKit owns it).
    static func inlineSpans(in blocks: [BlockNode]) -> [Span] {
        var out: [Span] = []
        for block in blocks {
            switch block {
            case .paragraph(_, let inlines),
                 .heading(_, _, _, let inlines),
                 .blockquote(_, let inlines):
                collectInlineSpans(inlines, into: &out)
            case .list(_, let items):
                for item in items { collectInlineSpans(item.inlines, into: &out) }
            case .ext(let node):
                collectInlineSpans(node.inlines, into: &out)
            case .codeBlock, .blockLatex, .table, .thematicBreak, .blank:
                break
            }
        }
        return out
    }

    private static func collectInlineSpans(_ nodes: [InlineNode], into out: inout [Span]) {
        for node in nodes {
            switch node {
            case .emphasis(_, let range, let markers, let children):
                if markers.count == 2 {
                    out.append(Span(range: range, open: markers[0],
                                    content: NSRange(location: NSMaxRange(markers[0]),
                                                     length: markers[1].location - NSMaxRange(markers[0])),
                                    close: markers[1]))
                }
                collectInlineSpans(children, into: &out)
            case .code(let range, let content):
                out.append(Span(range: range,
                                open: NSRange(location: range.location,
                                              length: content.location - range.location),
                                content: content,
                                close: NSRange(location: NSMaxRange(content),
                                               length: NSMaxRange(range) - NSMaxRange(content))))
            case .link(let range, let textRange, _, let markers, let children):
                // The close covers `](url)` whole: the URL hides with it.
                if markers.count == 4 {
                    out.append(Span(range: range, open: markers[0], content: textRange,
                                    close: NSRange(location: markers[1].location,
                                                   length: NSMaxRange(range) - markers[1].location)))
                }
                collectInlineSpans(children, into: &out)
            case .wikiLink(let range, let name, _, let markers):
                if markers.count == 2 {
                    out.append(Span(range: range, open: markers[0], content: name,
                                    close: markers[1]))
                }
            case .image(let range, let alt, _, let markers):
                // Unlike a link's, an image's `(url)` stays visible text —
                // only the four bracket/paren runs hide — so the image reads
                // as TWO spans: the `![alt]` ref and the `(url)` tail. One
                // span over both would teleport a delete from the visible
                // URL into the alt text.
                if markers.count == 4 {
                    out.append(Span(range: NSRange(location: range.location,
                                                  length: NSMaxRange(markers[1]) - range.location),
                                    open: markers[0], content: alt, close: markers[1]))
                    let url = NSRange(location: NSMaxRange(markers[2]),
                                      length: markers[3].location - NSMaxRange(markers[2]))
                    out.append(Span(range: NSRange(location: markers[2].location,
                                                  length: NSMaxRange(range) - markers[2].location),
                                    open: markers[2], content: url, close: markers[3]))
                }
            case .imageEmbed(let range, let target, let markers):
                if markers.count == 2 {
                    out.append(Span(range: range, open: markers[0], content: target,
                                    close: markers[1]))
                }
            case .escape(let range, let character, let marker):
                out.append(Span(range: range, open: marker, content: character,
                                close: NSRange(location: NSMaxRange(range), length: 0)))
            case .ext(let node):
                if node.markers.count == 2 {
                    out.append(Span(range: node.range, open: node.markers[0],
                                    content: node.contentRange, close: node.markers[1]))
                }
                collectInlineSpans(node.children, into: &out)
            case .inlineLatex, .text:
                break
            }
        }
    }

    /// Backspace beside hidden markers. Pass A (at/past content end) eats
    /// the last content grapheme — or the whole span when it is the last
    /// one. Pass B (at/before content start) eats the visible char before
    /// the span, stepping left past hidden markers and block prefixes.
    static func backspaceRange(string: NSString, spans: [Span],
                              prefixes: [(lineStart: Int, prefixEnd: Int)], caret: Int) -> NSRange? {
        let closers = spans.filter {
            caret >= NSMaxRange($0.content) && caret <= NSMaxRange($0.range)
        }
        // Innermost first: nested spans overlap, and the tightest one owns
        // the caret.
        if let span = closers.min(by: { $0.range.length < $1.range.length }) {
            if span.content.length == 0 { return span.range }
            let target = string.rangeOfComposedCharacterSequence(at: NSMaxRange(span.content) - 1)
            return target == span.content ? span.range : target
        }
        let openers = spans.filter {
            caret >= $0.range.location && caret <= $0.content.location
        }
        if let span = openers.min(by: { $0.range.length < $1.range.length }) {
            guard let deletion = charBefore(string: string, spans: spans, prefixes: prefixes,
                                           spanStart: span.range.location)
            else {
                // Nothing visible before the span: swallow rather than let
                // AppKit eat a hidden marker.
                return NSRange(location: caret, length: 0)
            }
            return deletion
        }
        return nil
    }

    /// The visible char before a span start, stepping left over hidden
    /// open/close markers and block prefixes. Nil when nothing visible
    /// precedes it (document start).
    private static func charBefore(string: NSString, spans: [Span],
                                  prefixes: [(lineStart: Int, prefixEnd: Int)],
                                  spanStart: Int) -> NSRange? {
        var i = spanStart - 1
        // Hop cap: every hop strictly moves the index and real parses never
        // nest marker runs, so this is paranoia against a pathological
        // overlapping parse looping forever — 8 is far past any real chain.
        var hops = 0
        while i >= 0 {
            if let covering = spans.first(where: {
                NSLocationInRange(i, $0.open) || NSLocationInRange(i, $0.close)
            }) {
                // Inside a closer the visible char sits at that span's end,
                // so this is that span's pass-A decision (markers can't
                // overlap, so the next char is exactly its end).
                if NSLocationInRange(i, covering.close) {
                    if covering.content.length == 0 { return covering.range }
                    let target = string.rangeOfComposedCharacterSequence(
                        at: NSMaxRange(covering.content) - 1)
                    return target == covering.content ? covering.range : target
                }
                i = covering.range.location - 1
            } else if let prefix = prefixes.first(where: { $0.lineStart <= i && i < $0.prefixEnd }) {
                i = prefix.lineStart - 1
            } else {
                return string.rangeOfComposedCharacterSequence(at: i)
            }
            hops += 1
            guard hops < 8 else { return nil }
        }
        return nil
    }

    /// Forward-delete mirror: at/before content start eats the first
    /// content grapheme (or the whole span when last); before a hidden
    /// closer it skips to whatever is visible past the span.
    static func forwardDeleteRange(string: NSString, spans: [Span], caret: Int) -> NSRange? {
        let openers = spans.filter {
            caret >= $0.range.location && caret <= $0.content.location
        }
        if let span = openers.min(by: { $0.range.length < $1.range.length }) {
            if span.content.length == 0 { return span.range }
            let target = string.rangeOfComposedCharacterSequence(at: span.content.location)
            return target == span.content ? span.range : target
        }
        let closers = spans.filter {
            caret >= NSMaxRange($0.content) && caret < NSMaxRange($0.range)
        }
        if let span = closers.min(by: { $0.range.length < $1.range.length }) {
            return charAfter(string: string, spans: spans,
                            spanEnd: NSMaxRange(span.range), fallbackCaret: caret)
        }
        return nil
    }

    /// The visible char past a span end, stepping right over hidden
    /// markers. An empty range (swallow) when nothing visible follows —
    /// passing through would eat a hidden closer.
    private static func charAfter(string: NSString, spans: [Span], spanEnd: Int,
                                 fallbackCaret: Int) -> NSRange {
        var i = spanEnd
        // Hop cap: same paranoia as the leftward walk, mirrored.
        var hops = 0
        while i < string.length {
            if let covering = spans.first(where: {
                NSLocationInRange(i, $0.open) || NSLocationInRange(i, $0.close)
            }) {
                // An opener ahead means that span's first content grapheme
                // (or the whole span when last) — the same decision as
                // landing there.
                if NSLocationInRange(i, covering.open) {
                    if covering.content.length == 0 { return covering.range }
                    let target = string.rangeOfComposedCharacterSequence(
                        at: covering.content.location)
                    return target == covering.content ? covering.range : target
                }
                i = NSMaxRange(covering.range)
            } else {
                return string.rangeOfComposedCharacterSequence(at: i)
            }
            hops += 1
            guard hops < 8 else { break }
        }
        return NSRange(location: fallbackCaret, length: 0)
    }

    // MARK: - Block prefixes

    /// Backspace at the content start of a converted heading/list/quote
    /// line removes the hidden prefix AND the newline in one step, joining
    /// up as plain text. The caret must sit past the line start (a caret
    /// exactly at it joins normally through AppKit) on the prefix's own
    /// line (this keeps Setext `===` underlines out of it).
    ///
    /// An EMPTY converted line un-converts in place instead: the bullet
    /// goes, the caret lands at the line start, and the line (and its
    /// break) stays — deleting the newline out from under a just-made
    /// empty item is never what backspace means there.
    static func blockPrefixJoin(string: NSString,
                               prefixes: [(lineStart: Int, prefixEnd: Int)], caret: Int) -> NSRange? {
        let caretLine = string.paragraphRange(for: NSRange(location: min(caret, string.length), length: 0))
        for prefix in prefixes {
            guard prefix.lineStart == caretLine.location,
                  caret > prefix.lineStart, caret <= prefix.prefixEnd
            else { continue }
            if restOfLineIsBlank(string: string, from: prefix.prefixEnd, line: caretLine) {
                return NSRange(location: prefix.lineStart,
                               length: lineContentEnd(string: string, line: caretLine) - prefix.lineStart)
            }
            let delStart: Int
            if prefix.lineStart > 0, string.character(at: prefix.lineStart - 1) == Self.newline {
                delStart = prefix.lineStart - 1
            } else {
                delStart = prefix.lineStart
            }
            return NSRange(location: delStart, length: prefix.prefixEnd - delStart)
        }
        return nil
    }

    /// End of a logical line's content (any trailing newline excluded).
    private static func lineContentEnd(string: NSString, line: NSRange) -> Int {
        var end = NSMaxRange(line)
        while end > line.location {
            let c = string.character(at: end - 1)
            guard c == Self.newline || c == Self.carriageReturn else { break }
            end -= 1
        }
        return end
    }

    /// Blank from `offset` to the line's content end (spaces/tabs only, so
    /// a hard-break's stray spaces count as empty and go with the prefix).
    private static func restOfLineIsBlank(string: NSString, from offset: Int, line: NSRange) -> Bool {
        let end = lineContentEnd(string: string, line: line)
        var i = max(offset, line.location)
        while i < end {
            let c = string.character(at: i)
            guard c == Self.space || c == Self.tab else { return false }
            i += 1
        }
        return true
    }

    /// Forward delete exactly at a converted line's start strips the hidden
    /// prefix in place. Without this AppKit eats one hidden `#` (or `-`,
    /// `>`) per press while the line renders unchanged — dead keys.
    static func blockPrefixStrip(prefixes: [(lineStart: Int, prefixEnd: Int)], caret: Int) -> NSRange? {
        prefixes.first(where: { $0.lineStart == caret && $0.prefixEnd > caret })
            .map { NSRange(location: $0.lineStart, length: $0.prefixEnd - $0.lineStart) }
    }

    /// (line start, content start) for every converted line, read off the
    /// parse — headings and lists carry their marker ranges; quote markers
    /// are matched strictly on lines the parser already calls blockquotes.
    static func blockPrefixes(string: NSString, blocks: [BlockNode]) -> [(lineStart: Int, prefixEnd: Int)] {
        var out: [(Int, Int)] = []
        for block in blocks {
            switch block {
            case .heading(_, let range, let markers, _):
                let lineStart = string.paragraphRange(for: NSRange(location: range.location, length: 0)).location
                let prefixEnd = markers.map(NSMaxRange).max() ?? range.location
                if prefixEnd > lineStart { out.append((lineStart, prefixEnd)) }
            case .list(_, let items):
                for item in items {
                    let lineStart = string.paragraphRange(
                        for: NSRange(location: item.range.location, length: 0)).location
                    if item.contentRange.location > lineStart {
                        out.append((lineStart, item.contentRange.location))
                    }
                }
            case .blockquote(let range, _):
                var lineStart = string.paragraphRange(
                    for: NSRange(location: range.location, length: 0)).location
                let end = NSMaxRange(range)
                while lineStart < end {
                    let line = string.paragraphRange(for: NSRange(location: lineStart, length: 0))
                    if let prefixEnd = quotePrefixEnd(string: string, line: line) {
                        out.append((line.location, prefixEnd))
                    }
                    lineStart = NSMaxRange(line)
                }
            case .paragraph, .codeBlock, .blockLatex, .table, .thematicBreak, .blank, .ext:
                break
            }
        }
        return out
    }

    /// End offset of a `>` prefix run on one logical line, or nil. Each
    /// level takes one optional trailing space or tab — the same run the
    /// styler hides whole. Lines the matcher skips keep stock backspace.
    private static func quotePrefixEnd(string: NSString, line: NSRange) -> Int? {
        var i = line.location
        let end = min(NSMaxRange(line), string.length)
        var spaces = 0
        while i < end, string.character(at: i) == Self.space, spaces < 4 {
            i += 1
            spaces += 1
        }
        guard spaces < 4 else { return nil }
        var depth = 0
        while i < end, string.character(at: i) == Self.closeAngle {
            depth += 1
            i += 1
            if i < end,
               string.character(at: i) == Self.space || string.character(at: i) == Self.tab {
                i += 1
            }
        }
        return depth > 0 ? i : nil
    }

    private static let newline: unichar = 0x0A
    private static let carriageReturn: unichar = 0x0D
    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09
    private static let closeAngle: unichar = 0x3E // >
}
