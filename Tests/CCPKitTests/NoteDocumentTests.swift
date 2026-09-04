// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import Foundation
import XCTest

final class NoteDocumentTests: XCTestCase {
    // MARK: - Model

    func testBlankDocumentIsEmptyButHasABlockToTypeInto() {
        XCTAssertTrue(NoteDocument.blank.isEmpty)
        XCTAssertEqual(NoteDocument.blank.blocks.count, 1)
    }

    func testDividerIsNotEmptyDespiteHavingNoText() {
        XCTAssertFalse(NoteDocument(blocks: [NoteBlock(.divider)]).isEmpty)
    }

    func testPlainTextJoinsBlocksWithNewlines() {
        let document = NoteDocument(blocks: [
            NoteBlock(.heading(level: 1), text: "Title"),
            NoteBlock(.paragraph, text: "Body"),
        ])
        XCTAssertEqual(document.plainText, "Title\nBody")
    }

    func testNormalizeClampsHeadingLevelAndIndent() {
        let document = NoteDocument(blocks: [
            NoteBlock(.heading(level: 99), indent: -4, text: "Shout"),
        ]).normalized()
        XCTAssertEqual(document.blocks[0].kind, .heading(level: 6))
        XCTAssertEqual(document.blocks[0].indent, 0)
    }

    func testNormalizeMergesAdjacentRunsSharingAStyle() {
        // Typing splits runs at every boundary; two notes that read the same
        // must compare equal or a store writes on each keystroke.
        let split = NoteDocument(blocks: [
            NoteBlock(.paragraph, inlines: [
                NoteInline("he"), NoteInline("llo"), NoteInline(" bold", marks: .bold),
            ]),
        ]).normalized()
        let whole = NoteDocument(blocks: [
            NoteBlock(.paragraph, inlines: [
                NoteInline("hello"), NoteInline(" bold", marks: .bold),
            ]),
        ]).normalized()
        XCTAssertEqual(split, whole)
        XCTAssertEqual(split.blocks[0].inlines.count, 2)
    }

    func testNormalizeDropsEmptyRuns() {
        let document = NoteDocument(blocks: [
            NoteBlock(.paragraph, inlines: [NoteInline(""), NoteInline("kept")]),
        ]).normalized()
        XCTAssertEqual(document.blocks[0].inlines, [NoteInline("kept")])
    }

    func testCodableRoundTrip() throws {
        let document = NoteDocument(blocks: [
            NoteBlock(.todo(isDone: true), indent: 1, text: "done"),
            NoteBlock(.code(language: "swift"), text: "let x = 1"),
            NoteBlock(.paragraph, inlines: [
                NoteInline("link", style: NoteInlineStyle(marks: .bold,
                                                          link: URL(string: "https://example.com"))),
            ]),
        ])
        let data = try JSONEncoder().encode(document)
        XCTAssertEqual(try JSONDecoder().decode(NoteDocument.self, from: data), document)
    }

    // MARK: - AttributedString

    func testAttributedStringRoundTripPreservesBlocks() {
        let document = NoteDocument(blocks: [
            NoteBlock(.heading(level: 2), text: "Heading"),
            NoteBlock(.paragraph, inlines: [
                NoteInline("plain "), NoteInline("bold", marks: .bold),
            ]),
            NoteBlock(.bulleted, indent: 1, text: "nested item"),
            NoteBlock(.todo(isDone: true), text: "shipped"),
            NoteBlock(.divider),
        ])
        XCTAssertEqual(NoteDocument(document.attributedString), document.normalized())
    }

    func testAttributedStringKeepsConsecutiveParagraphsApart() {
        // Alike in every attribute but position — without that they read back
        // as one block with a newline inside it.
        let document = NoteDocument(blocks: [
            NoteBlock(.paragraph, text: "first"),
            NoteBlock(.paragraph, text: "second"),
        ])
        XCTAssertEqual(NoteDocument(document.attributedString).blocks.count, 2)
    }

    func testAttributedStringCarriesInlineIntentForRendering() {
        let document = NoteDocument(blocks: [
            NoteBlock(.paragraph, inlines: [NoteInline("bold", marks: .bold)]),
        ])
        let run = document.attributedString.runs.first
        XCTAssertEqual(run?.inlinePresentationIntent, .stronglyEmphasized)
    }

    func testEmptyAttributedStringReadsAsBlank() {
        XCTAssertEqual(NoteDocument(AttributedString()), NoteDocument.blank)
    }

    // MARK: - Markdown

    func testParsesMarkdownBlocks() {
        let document = NoteDocument(markdown: """
        # Title

        Some **bold** text.

        - one
        - two

        ---
        """)
        XCTAssertEqual(document.blocks.first?.kind, .heading(level: 1))
        XCTAssertEqual(document.blocks.map(\.kind).filter { $0 == .bulleted }.count, 2)
        XCTAssertTrue(document.blocks.contains { $0.kind == .divider })
    }

    func testParsesInlineMarks() {
        let document = NoteDocument(markdown: "a **b** _c_ `d`")
        let marks = document.blocks[0].inlines.map(\.style.marks)
        XCTAssertTrue(marks.contains(.bold))
        XCTAssertTrue(marks.contains(.italic))
        XCTAssertTrue(marks.contains(.code))
    }

    func testEmitsMarkdownForEachBlockKind() {
        let document = NoteDocument(blocks: [
            NoteBlock(.heading(level: 3), text: "Head"),
            NoteBlock(.bulleted, text: "item"),
            NoteBlock(.numbered, text: "first"),
            NoteBlock(.numbered, text: "second"),
            NoteBlock(.todo(isDone: false), text: "todo"),
            NoteBlock(.quote, text: "quoted"),
            NoteBlock(.divider),
        ])
        XCTAssertEqual(document.markdown, """
        ### Head

        - item

        1. first

        2. second

        - [ ] todo

        > quoted

        ---
        """)
    }

    func testNumberedListRestartsAfterAnotherBlock() {
        let document = NoteDocument(blocks: [
            NoteBlock(.numbered, text: "one"),
            NoteBlock(.paragraph, text: "interruption"),
            NoteBlock(.numbered, text: "one again"),
        ])
        XCTAssertTrue(document.markdown.hasSuffix("1. one again"))
    }

    func testEmitsInlineMarksAndLinks() {
        let document = NoteDocument(blocks: [
            NoteBlock(.paragraph, inlines: [
                NoteInline("b", marks: .bold),
                NoteInline("i", marks: .italic),
                NoteInline("c", marks: .code),
                NoteInline("l", style: NoteInlineStyle(link: URL(string: "https://example.com"))),
            ]),
        ])
        XCTAssertEqual(document.markdown, "**b**_i_`c`[l](https://example.com)")
    }

    func testMarkdownRoundTripKeepsStructureAndStyle() {
        let source = NoteDocument(blocks: [
            NoteBlock(.heading(level: 2), text: "Notes"),
            NoteBlock(.paragraph, inlines: [
                NoteInline("some "), NoteInline("bold", marks: .bold), NoteInline(" text"),
            ]),
            NoteBlock(.bulleted, text: "one"),
            NoteBlock(.bulleted, text: "two"),
        ])
        XCTAssertEqual(NoteDocument(markdown: source.markdown), source.normalized())
    }
}

// MARK: - Round-trip fidelity
//
// Markdown is the format an export writes and a block-less backend holds, so
// text that merely *looks* like markup has to survive a write-then-read.

final class NoteDocumentRoundTripTests: XCTestCase {
    private func assertRoundTrips(_ blocks: [NoteBlock],
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        let document = NoteDocument(blocks: blocks).normalized()
        XCTAssertEqual(NoteDocument(markdown: document.markdown), document,
                       "markdown was: \(document.markdown)", file: file, line: line)
    }

    func testLiteralBlockMarkersStayText() {
        assertRoundTrips([NoteBlock(.paragraph, text: "- not a list")])
        assertRoundTrips([NoteBlock(.paragraph, text: "# not a heading")])
        assertRoundTrips([NoteBlock(.paragraph, text: "1. not a list")])
        assertRoundTrips([NoteBlock(.paragraph, text: "> not a quote")])
    }

    func testLiteralInlineMarkersStayUnstyled() {
        assertRoundTrips([NoteBlock(.paragraph, text: "*text with star* around")])
        assertRoundTrips([NoteBlock(.paragraph, text: "snake_case_name")])
        assertRoundTrips([NoteBlock(.paragraph, text: "a `tick` b")])
        assertRoundTrips([NoteBlock(.paragraph, text: "[brackets] (parens)")])
        assertRoundTrips([NoteBlock(.paragraph, text: "a \\ backslash")])
    }

    func testConsecutiveParagraphsStayTwoBlocks() {
        assertRoundTrips([
            NoteBlock(.paragraph, text: "first"),
            NoteBlock(.paragraph, text: "second"),
        ])
    }

    func testCodeSpanContainingBackticks() {
        assertRoundTrips([
            NoteBlock(.paragraph, inlines: [NoteInline("a`b", marks: .code)]),
        ])
    }

    func testCodeBlockKeepsTrailingBlankLines() {
        let attributed = NoteDocument(blocks: [
            NoteBlock(.code(language: nil), text: "foo\n\n"),
        ]).attributedString
        XCTAssertEqual(NoteDocument(attributed).blocks[0].plainText, "foo\n\n")
    }
}

// MARK: - Editing

final class NoteDocumentEditingTests: XCTestCase {
    // MARK: Return splits a block

    func testNewlineInAParagraphStartsAnotherParagraph() {
        var attributed = AttributedString("first\nsecond")
        attributed.noteBlockKind = .paragraph
        attributed.noteBlockPosition = 0
        let document = NoteDocument(attributed)
        XCTAssertEqual(document.blocks.map(\.plainText), ["first", "second"])
        XCTAssertEqual(document.blocks.map(\.kind), [.paragraph, .paragraph])
    }

    func testNewlineInAHeadingDropsToAParagraph() {
        var attributed = AttributedString("Title\nbody")
        attributed.noteBlockKind = .heading(level: 1)
        attributed.noteBlockPosition = 0
        XCTAssertEqual(NoteDocument(attributed).blocks.map(\.kind),
                       [.heading(level: 1), .paragraph])
    }

    func testNewlineInAListItemStartsAnotherItem() {
        var attributed = AttributedString("one\ntwo")
        attributed.noteBlockKind = .bulleted
        attributed.noteBlockPosition = 0
        XCTAssertEqual(NoteDocument(attributed).blocks.map(\.kind), [.bulleted, .bulleted])
    }

    func testNewlineInADoneTodoStartsAnUncheckedOne() {
        var attributed = AttributedString("shipped\nnext")
        attributed.noteBlockKind = .todo(isDone: true)
        attributed.noteBlockPosition = 0
        XCTAssertEqual(NoteDocument(attributed).blocks.map(\.kind),
                       [.todo(isDone: true), .todo(isDone: false)])
    }

    func testNewlineInACodeBlockStaysInTheBlock() {
        var attributed = AttributedString("let a = 1\nlet b = 2")
        attributed.noteBlockKind = .code(language: nil)
        attributed.noteBlockPosition = 0
        let document = NoteDocument(attributed)
        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(document.blocks[0].plainText, "let a = 1\nlet b = 2")
    }

    // MARK: Marks over a selection

    private func attributed(_ string: String) -> AttributedString { AttributedString(string) }

    func testTogglingAMarkOnPlainTextTurnsItOn() {
        let text = attributed("hello")
        let toggled = text.togglingMark(.bold, in: [text.startIndex..<text.endIndex])
        XCTAssertTrue(toggled.hasMark(.bold, in: [toggled.startIndex..<toggled.endIndex]))
    }

    func testTogglingAFullyMarkedSelectionTurnsItOff() {
        var text = attributed("hello")
        text.inlinePresentationIntent = .stronglyEmphasized
        let toggled = text.togglingMark(.bold, in: [text.startIndex..<text.endIndex])
        XCTAssertFalse(toggled.hasMark(.bold, in: [toggled.startIndex..<toggled.endIndex]))
    }

    func testTogglingAPartlyMarkedSelectionFinishesTheJob() {
        // Half bold: pressing bold should make all of it bold, not clear it.
        var text = attributed("hello")
        let middle = text.index(text.startIndex, offsetByCharacters: 2)
        text[text.startIndex..<middle].inlinePresentationIntent = .stronglyEmphasized
        let whole = text.startIndex..<text.endIndex
        XCTAssertFalse(text.hasMark(.bold, in: [whole]))
        XCTAssertTrue(text.togglingMark(.bold, in: [whole]).hasMark(.bold, in: [whole]))
    }

    func testTogglingKeepsOtherMarks() {
        var text = attributed("hello")
        text.inlinePresentationIntent = .emphasized
        let whole = text.startIndex..<text.endIndex
        let bolded = text.togglingMark(.bold, in: [whole])
        XCTAssertTrue(bolded.hasMark(.italic, in: [whole]))
        XCTAssertTrue(bolded.hasMark(.bold, in: [whole]))
    }

    func testAnEmptySelectionHasNoMarkAndTogglingIsANoOp() {
        let text = attributed("hello")
        XCTAssertFalse(text.hasMark(.bold, in: []))
        XCTAssertEqual(text.togglingMark(.bold, in: []), text)
    }
}
