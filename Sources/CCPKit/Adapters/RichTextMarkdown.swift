// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import Foundation

/// Styled clipboard bytes → the Markdown a note holds.
///
/// A drop carrying RTF/HTML lands as `**bold**`, `*italic*`, `[text](url)`
/// and paragraphs instead of bare text, so a styled copy keeps its shape in
/// a Markdown surface. Anything without a Markdown form — colors, fonts,
/// sizes, embedded images — is shed, and anything unparseable returns nil
/// for the plain-string fallback. Converting never fails a drop; it only
/// decides whether the drop keeps its styling.
public enum RichTextMarkdown {
    /// Markdown for the first parseable blob (RTF before HTML, matching
    /// capture fidelity), else nil.
    public static func markdown(rtf: Data?, html: Data?) -> String? {
        let blobs: [(data: Data?, parse: (Data) -> NSAttributedString?)] = [
            (rtf, { NSAttributedString(rtf: $0, documentAttributes: nil) }),
            (html, { NSAttributedString(html: $0, documentAttributes: nil) }),
        ]
        for blob in blobs {
            guard let data = blob.data, !data.isEmpty,
                  let attributed = blob.parse(data),
                  hasVisibleContent(attributed.string) else { continue }
            let converted = markdown(attributed: attributed)
            if !converted.isEmpty { return converted }
        }
        return nil
    }

    /// Whether the parsed string holds anything a note could show. The HTML
    /// reader returns junk control bytes rather than nil for garbage input,
    /// and those must fall through to plain instead of replacing it.
    private static func hasVisibleContent(_ string: String) -> Bool {
        string.unicodeScalars.contains {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    static func markdown(attributed: NSAttributedString) -> String {
        var paragraphs: [String] = []
        var current = ""
        let breaks = CharacterSet(charactersIn: "\n\r\u{2028}\u{2029}")
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: full, options: []) { attributes, range, _ in
            let run = (attributed.string as NSString).substring(with: range)
            var segment = ""
            func flushSegment() {
                current += inline(segment, attributes: attributes)
                segment = ""
            }
            func flushParagraph() {
                flushSegment()
                paragraphs.append(current)
                current = ""
            }
            for character in run {
                // Swift sees CRLF as one Character, so it needs its own
                // case — otherwise the pair rides along literally and the
                // markers leak across the break.
                if character == "\r\n" {
                    flushParagraph()
                } else if character.unicodeScalars.count == 1,
                          let scalar = character.unicodeScalars.first,
                          breaks.contains(scalar) {
                    flushParagraph()
                } else if character != "\u{FFFC}" {
                    // Attachments have no text form in a note; shed them
                    // where they stand rather than emitting markers.
                    segment.append(character)
                }
            }
            flushSegment()
        }
        paragraphs.append(current)
        return paragraphs
            .map { escapeBlockOpener($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n\n")
    }

    /// A literal `-`, `+` or `>` opening a paragraph would reparse as a list
    /// or quote. Escaped only there — mid-text dashes stay literal, since
    /// escaping every one would riddle ordinary prose.
    private static func escapeBlockOpener(_ paragraph: String) -> String {
        guard let first = paragraph.first, "-+>".contains(first) else { return paragraph }
        let rest = paragraph.dropFirst()
        guard rest.first == " " || rest.first == "\t" else { return paragraph }
        return "\\" + paragraph
    }

    private static func inline(_ segment: String,
                               attributes: [NSAttributedString.Key: Any]) -> String {
        guard !segment.isEmpty else { return "" }
        // Code renders literally, so its content skips the escape pass —
        // bolding a code span still wraps it, which is safe because the
        // content holds no live markers.
        var inner = isMonospaced(attributes) ? codeSpan(segment) : escape(segment)
        let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
        if traits.contains(.bold) && traits.contains(.italic) {
            inner = "***\(inner)***"
        } else if traits.contains(.bold) {
            inner = "**\(inner)**"
        } else if traits.contains(.italic) {
            inner = "*\(inner)*"
        }
        if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 {
            inner = "~~\(inner)~~"
        }
        if let url = linkURL(attributes) {
            inner = "[\(inner)](\(escapeDestination(url)))"
        }
        return inner
    }

    /// Code-span delimiting that survives backticks in the content.
    private static func codeSpan(_ text: String) -> String {
        text.contains("`") ? "`` \(text) ``" : "`\(text)`"
    }

    /// Destinations travel encoded: a raw `)` would end the link early and
    /// a raw space would split it. The encoded form renders and follows
    /// identically.
    private static func escapeDestination(_ url: String) -> String {
        url.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    private static func linkURL(_ attributes: [NSAttributedString.Key: Any]) -> String? {
        if let url = attributes[.link] as? URL { return url.absoluteString }
        if let string = attributes[.link] as? String, !string.isEmpty { return string }
        return nil
    }

    /// Fixed-pitch by trait. A miss degrades to prose, which beats a name
    /// heuristic guessing wrong and littering backticks.
    private static func isMonospaced(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true
    }

    /// The inline corruptors: characters that would reparse as Markdown and
    /// change what the pasted words say. `~` joins them as the converter's
    /// own syntax; `-`/`>`/`1.` openers are handled at paragraph start
    /// instead, since escaping every dash would riddle ordinary prose.
    private static let escapable: Set<Character> =
        ["\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "+", "~"]

    private static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            if escapable.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
