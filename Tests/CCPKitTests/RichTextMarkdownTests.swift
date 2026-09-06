// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import Foundation
import XCTest
@testable import CCPKit

/// Styled clipboard bytes become the Markdown a note holds: inline styles,
/// links and paragraphs survive, everything without a Markdown form sheds,
/// and garbage degrades to the plain fallback.
final class RichTextMarkdownTests: XCTestCase {
    private func styled() -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        result.append(NSAttributedString(
            string: "Hello",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
        result.append(NSAttributedString(string: " "))
        result.append(NSAttributedString(
            string: "world",
            attributes: [.font: NSFontManager.shared.convert(
                NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)]))
        result.append(NSAttributedString(string: ", click "))
        result.append(NSAttributedString(
            string: "here",
            attributes: [.link: URL(string: "https://example.com")!]))
        return result
    }

    private func rtfData(for attributed: NSAttributedString) throws -> Data {
        try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    func testInlineStylesAndLink() {
        XCTAssertEqual(
            RichTextMarkdown.markdown(attributed: styled()),
            "**Hello** *world*, click [here](https://example.com)")
    }

    func testRTFRoundTrip() throws {
        let rtf = try rtfData(for: styled())
        XCTAssertEqual(
            RichTextMarkdown.markdown(rtf: rtf, html: nil),
            "**Hello** *world*, click [here](https://example.com)")
    }

    func testHTML() {
        let html = Data(
            "<b>Bold</b> and <a href=\"https://example.com\">linked</a>".utf8)
        XCTAssertEqual(
            RichTextMarkdown.markdown(rtf: nil, html: html),
            "**Bold** and [linked](https://example.com/)")
    }

    func testPrefersRTF() throws {
        let rtf = try rtfData(for: styled())
        let html = Data("<i>other</i>".utf8)
        XCTAssertEqual(
            RichTextMarkdown.markdown(rtf: rtf, html: html),
            "**Hello** *world*, click [here](https://example.com)")
    }

    func testNilWhenUnparseable() {
        XCTAssertNil(RichTextMarkdown.markdown(rtf: nil, html: nil))
        XCTAssertNil(RichTextMarkdown.markdown(rtf: Data([0, 1, 2]), html: nil))
    }

    /// The HTML reader yields control bytes rather than nil for garbage, and
    /// those must fall through instead of replacing good text.
    func testJunkHTMLFallsThrough() {
        XCTAssertNil(RichTextMarkdown.markdown(rtf: nil, html: Data([0, 1, 2])))
    }

    func testEscapesMarkdown() {
        let plain = NSAttributedString(string: "a*b_c[d]")
        XCTAssertEqual(RichTextMarkdown.markdown(attributed: plain), "a\\*b\\_c\\[d\\]")
    }

    func testLiteralFormattingSyntaxStaysLiteral() {
        XCTAssertEqual(
            RichTextMarkdown.markdown(attributed: NSAttributedString(string: "~~hey~~")),
            "\\~\\~hey\\~\\~")
        XCTAssertEqual(
            RichTextMarkdown.markdown(attributed: NSAttributedString(string: "- hello")),
            "\\- hello")
        XCTAssertEqual(
            RichTextMarkdown.markdown(attributed: NSAttributedString(string: "> hello")),
            "\\> hello")
        XCTAssertEqual(
            RichTextMarkdown.markdown(attributed: NSAttributedString(string: "well-known - ok")),
            "well-known - ok")
    }

    func testLinkDestinationEscaped() {
        let linked = NSAttributedString(
            string: "click",
            attributes: [.link: URL(string: "https://example.com/a)b c")!])
        XCTAssertEqual(
            RichTextMarkdown.markdown(attributed: linked),
            "[click](https://example.com/a%29b%20c)")
    }

    func testCRLF() {
        let bold = NSAttributedString(
            string: "a\r\nb",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        XCTAssertEqual(RichTextMarkdown.markdown(attributed: bold), "**a**\n\n**b**")
    }

    func testCodeSkipsEscape() {
        let code = NSAttributedString(
            string: "a*b",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
        XCTAssertEqual(RichTextMarkdown.markdown(attributed: code), "`a*b`")
    }

    func testStrikethroughAndMono() {
        let result = NSMutableAttributedString(string: "")
        result.append(NSAttributedString(
            string: "gone",
            attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue]))
        result.append(NSAttributedString(string: " "))
        result.append(NSAttributedString(
            string: "code",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
        XCTAssertEqual(RichTextMarkdown.markdown(attributed: result), "~~gone~~ `code`")
    }

    func testAttachmentsShed() {
        let result = NSMutableAttributedString(string: "before ")
        result.append(NSAttributedString(attachment: NSTextAttachment()))
        result.append(NSAttributedString(string: " after"))
        XCTAssertEqual(RichTextMarkdown.markdown(attributed: result), "before  after")
    }

    func testParagraphs() {
        let plain = NSAttributedString(string: "one\n\ntwo\nthree")
        XCTAssertEqual(RichTextMarkdown.markdown(attributed: plain), "one\n\ntwo\n\nthree")
    }
}
