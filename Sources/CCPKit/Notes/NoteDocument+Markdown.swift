// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Markdown in and out.
///
/// Not the storage format — `NoteStore` trades in `NoteDocument` — but the
/// lingua franca either side of it: what a paste arrives as, what an export
/// writes, and what a backend without blocks of its own would hold. Reading
/// goes through Foundation's parser and the `AttributedString` bridge beside
/// this, so there is one place that decides what a block is.
public extension NoteDocument {
    init(markdown: String) {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            self.init(plainText: markdown)
            return
        }
        self.init(parsed)
    }

    var markdown: String {
        var ordinals: [Int: Int] = [:]
        var lines: [String] = []

        for block in blocks {
            if case .numbered = block.kind {
                ordinals[block.indent, default: 0] += 1
            } else {
                ordinals[block.indent] = 0
            }
            // A shallower item ends any deeper numbering under it, so the next
            // nested list starts at one rather than continuing the last.
            for depth in ordinals.keys where depth > block.indent {
                ordinals[depth] = 0
            }
            lines.append(block.markdown(ordinal: ordinals[block.indent] ?? 1))
        }

        // A blank line, not a single newline: CommonMark reads one newline
        // between two plain lines as a soft break *inside* one paragraph, so
        // joining tightly would silently merge every paragraph the user
        // separated by pressing return.
        return lines.joined(separator: "\n\n")
    }
}

private extension NoteBlock {
    func markdown(ordinal: Int) -> String {
        let body = inlines.map(\.markdown).joined()
        let indentation = String(repeating: "  ", count: indent)

        switch kind {
        case .paragraph:
            return body.escapingLeadingBlockMarker()
        case .heading(let level):
            return String(repeating: "#", count: level) + " " + body
        case .bulleted:
            return indentation + "- " + body
        case .numbered:
            return indentation + "\(ordinal). " + body
        case .todo(let isDone):
            return indentation + (isDone ? "- [x] " : "- [ ] ") + body
        case .quote:
            return String(repeating: "> ", count: indent + 1) + body
        case .code(let language):
            // Code block content is literal, so it is the one place nothing is
            // escaped — the fence is what protects it.
            return "```\(language ?? "")\n\(plainText)\n```"
        case .divider:
            return "---"
        }
    }
}

private extension NoteInline {
    /// The run wrapped in its markers, innermost first so `**_text_**` nests
    /// the way a parser expects to unwrap it.
    var markdown: String {
        guard !text.isEmpty else { return "" }

        // A code span is literal: nothing inside it is emphasis, and it needs
        // a fence longer than the longest backtick run it contains.
        if style.marks.contains(.code) {
            return linked(text.fencedAsCodeSpan())
        }

        var result = text.escapingInlineMarkers()
        if style.marks.contains(.italic) { result = "_" + result + "_" }
        if style.marks.contains(.bold) { result = "**" + result + "**" }
        if style.marks.contains(.strikethrough) { result = "~~" + result + "~~" }
        return linked(result)
    }

    private func linked(_ body: String) -> String {
        guard let link = style.link else { return body }
        let destination = link.absoluteString
        // A bare destination cannot hold spaces or unbalanced parentheses;
        // the pointy-bracket form can.
        let needsBrackets = destination.contains(where: { $0 == " " || $0 == "(" || $0 == ")" })
        return "[\(body)](\(needsBrackets ? "<\(destination)>" : destination))"
    }
}

// MARK: - Escaping
//
// Text that merely looks like markup has to survive a write-then-read, or a
// note saying "- call the bank" comes back as a bullet and a heading appears
// where the user typed a hash.

private extension String {
    /// Characters a parser would read as inline markup rather than text.
    /// Backslash is first in the set and handled by the same pass, so an
    /// escape never escapes an escape twice.
    static let inlineMarkers: Set<Character> = ["\\", "*", "_", "`", "[", "]", "<", "~"]

    func escapingInlineMarkers() -> String {
        var escaped = ""
        escaped.reserveCapacity(count)
        for character in self {
            if Self.inlineMarkers.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// A paragraph opening with a block marker needs one backslash to stay a
    /// paragraph. Inline escaping has already dealt with `*` and `<`; these
    /// are the markers that only mean something at the start of a line.
    func escapingLeadingBlockMarker() -> String {
        let markers: Set<Character> = ["#", "-", "+", ">", "="]
        guard let first else { return self }
        if markers.contains(first) { return "\\" + self }

        // An ordered-list marker is digits then "." or ")".
        let digits = prefix(while: \.isNumber)
        guard !digits.isEmpty else { return self }
        let afterDigits = dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else {
            return self
        }
        return digits + "\\" + afterDigits
    }

    /// The string as a code span, fenced past its own backticks and padded
    /// where a backtick would otherwise touch the fence.
    func fencedAsCodeSpan() -> String {
        var longestRun = 0
        var run = 0
        for character in self {
            run = character == "`" ? run + 1 : 0
            longestRun = max(longestRun, run)
        }
        let fence = String(repeating: "`", count: longestRun + 1)
        let padding = (hasPrefix("`") || hasSuffix("`")) ? " " : ""
        return fence + padding + self + padding + fence
    }
}
