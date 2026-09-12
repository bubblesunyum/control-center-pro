// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// The documented read-only rule: which Craft markdown CCP must never write
/// back. The push side enforces it through the sidecar's `isWritable` flag;
/// the pull side classifies with this. ccp-occ owns the editor half (showing
/// such blocks inert and subtly marked; revert-guard until the fork lands
/// per-range regions in ccp-i7g).
///
/// A block whose markdown carries any tag the pad does not render is
/// read-only (ccp-occ, widened per ccp-prk tier 1). Three bands:
/// 1. UNWRITABLE BY THE API — output-only tags plus out-of-scope links.
///    Craft refuses these on input.
/// 2. WRITABLE BUT UNRENDERED — callouts, captions, nested pages, comments,
///    highlights and cards. Legal to PUT, but the engine draws them as
///    literal XML, so the user would be editing angle brackets.
/// 3. RENDERED — everything else: headings, bold, italics, inline code,
///    links, bullets, numbered items, task lists, blockquotes, fenced code.
///
/// The test is "contains a tag we do not render", not a denylist of known-bad
/// tags — a tag Craft adds next year is read-only by default rather than
/// silently flattened (fail safe, not fail open).
public enum CraftBlockPolicy {
    /// Tags Craft returns but the API will not accept on input.
    private static let outputOnlyTags = [
        "collection", "title", "properties", "collectionItem",
        "property", "contentPreview", "itemsPreview",
    ]

    /// Tags Craft accepts back but the pad cannot render (ccp-prk tier 1).
    /// `<highlight>` joins the rendered band if and when tier 2 registers it;
    /// until then it stays here.
    private static let unrenderedTags = [
        "callout", "caption", "page", "pageTitle",
        "content", "comment", "card", "highlight",
    ]

    private static let inlineCode = try! NSRegularExpression(pattern: "`[^`\n]+`")
    /// Any XML-ish tag: `<name>`, `</name>`, `<name attr="…">`, `<br/>`.
    /// Requires the closing `>` so `a<b` stays writable; autolinks like
    /// `<https://…>` never match because `:` cannot end a tag name.
    private static let tagPattern = try! NSRegularExpression(pattern: "</?[A-Za-z][A-Za-z0-9]*(\\s[^<>]*)?/?>")

    /// True when the markdown carries something Craft will not take back: an
    /// output-only tag, or a link to a target outside the connection's scope
    /// (PUTting that string back destroys the link). Also true for any tag
    /// the pad does not render (band 2 plus unknown future tags) — those
    /// blocks are read-only until the pad can render them.
    public static func isUnwritable(markdown: String) -> Bool {
        let prose = strippingCode(markdown)
        if prose.contains("invalid:out_of_scope") { return true }
        if prose.contains("<!--") { return true }
        if outputOnlyTags.contains(where: { containsTag(prose, $0) }) { return true }
        if unrenderedTags.contains(where: { containsTag(prose, $0) }) { return true }
        return containsUnknownTag(prose)
    }

    /// Code is literal text the user wrote, and it round-trips byte-identical
    /// — so a `<title>` in a sample must not classify the block. A whole
    /// fenced block strips entirely; inline spans strip single-line (an
    /// unclosed fence, or anything missed, scans raw and errs toward
    /// read-only, which is the safe direction).
    private static func strippingCode(_ markdown: String) -> String {
        if isFencedBlock(markdown.trimmingCharacters(in: .whitespacesAndNewlines)) { return "" }
        let range = NSRange(markdown.startIndex..., in: markdown)
        return inlineCode.stringByReplacingMatches(in: markdown, range: range, withTemplate: "")
    }

    private static func isFencedBlock(_ text: String) -> Bool {
        let fence = text.hasPrefix("```") ? "```" : text.hasPrefix("~~~") ? "~~~" : nil
        guard let fence else { return false }
        let lines = text.components(separatedBy: "\n")
        return lines.dropFirst().contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(fence)
        }
    }

    /// `<name` followed by a tag boundary, so `<title>` matches without
    /// `<titlex>` matching `title` by prefix. The generic fallback below
    /// catches unknown names anyway; the boundary keeps each named entry
    /// precise about what it names.
    private static func containsTag(_ markdown: String, _ name: String) -> Bool {
        var searchFrom = markdown.startIndex
        while let open = markdown.range(of: "<" + name, range: searchFrom..<markdown.endIndex) {
            let after = open.upperBound
            if after == markdown.endIndex { return true }
            let next = markdown[after]
            if next == ">" || next == "/" || next.isWhitespace { return true }
            searchFrom = after
        }
        return false
    }

    /// Fail-safe: any tag at all, including ones Craft adds next year.
    /// Named lists above document the known bands; this is what makes an
    /// unknown `<futureWidget>` read-only by default instead of silently
    /// flattened.
    private static func containsUnknownTag(_ markdown: String) -> Bool {
        let range = NSRange(markdown.startIndex..., in: markdown)
        return tagPattern.firstMatch(in: markdown, range: range) != nil
    }
}
