// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// The documented read-only rule: which Craft markdown CCP must never write
/// back. The push side enforces it through the sidecar's `isWritable` flag;
/// the pull side classifies with this. ccp-occ owns the editor half (showing
/// such blocks inert and subtly marked).
public enum CraftBlockPolicy {
    /// Tags Craft returns but the API will not accept on input.
    private static let outputOnlyTags = [
        "collection", "title", "properties", "collectionItem",
        "property", "contentPreview", "itemsPreview",
    ]

    private static let inlineCode = try! NSRegularExpression(pattern: "`[^`\n]+`")

    /// True when the markdown carries something Craft will not take back: an
    /// output-only tag, or a link to a target outside the connection's scope
    /// (PUTting that string back destroys the link).
    public static func isUnwritable(markdown: String) -> Bool {
        let prose = strippingCode(markdown)
        if prose.contains("invalid:out_of_scope") { return true }
        return outputOnlyTags.contains { containsTag(prose, $0) }
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

    /// `<name` followed by a tag boundary, so `<title>` matches but the
    /// round-trippable `<pageTitle>` does not.
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
}
