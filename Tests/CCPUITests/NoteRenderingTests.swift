// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import Foundation
import XCTest
@testable import CCPUI

/// The editor draws a bullet as ordinary characters, so everything here is
/// about telling those characters apart from the user's own — including after
/// the text view has handed the marker's attributes to text typed against it.
final class NoteRenderingTests: XCTestCase {
    // MARK: - Markers are not content

    func testTypingAgainstAMarkerKeepsTheTypedText() {
        // The defect this guards: text typed right after a bullet inherits the
        // bullet's attributes, so anything keyed on an attribute would drop
        // every character the user just wrote.
        var typed = NoteRendering.text(for: NoteDocument(blocks: [NoteBlock(.bulleted, text: "")]))
        let marker = NoteRendering.marker(for: NoteBlock(.bulleted))
        typed.characters.insert(contentsOf: "milk",
                                at: typed.index(typed.startIndex, offsetByCharacters: marker.count))

        let document = NoteRendering.document(from: typed)
        XCTAssertEqual(document.blocks.map(\.plainText), ["milk"])
        XCTAssertEqual(document.blocks.map(\.kind), [.bulleted])
    }

    func testMarkerIsShedOnRoundTrip() {
        for kind in [NoteBlock.Kind.bulleted, .numbered, .todo(isDone: false),
                     .todo(isDone: true), .quote, .paragraph] {
            let document = NoteDocument(blocks: [NoteBlock(kind, text: "content")])
            XCTAssertEqual(NoteRendering.document(from: NoteRendering.text(for: document)),
                           document.normalized(), "\(kind)")
        }
    }

    func testABlockOfOnlyItsMarkerIsAnEmptyBlockNotAMissingOne() {
        let document = NoteDocument(blocks: [NoteBlock(.todo(isDone: false), text: "")])
        let read = NoteRendering.document(from: NoteRendering.text(for: document))
        XCTAssertEqual(read.blocks.map(\.kind), [.todo(isDone: false)])
        XCTAssertTrue(read.blocks[0].plainText.isEmpty)
    }

    func testMarkersDoNotLeakIntoAMultiBlockNote() {
        let document = NoteDocument(blocks: [
            NoteBlock(.heading(level: 1), text: "Shopping"),
            NoteBlock(.bulleted, text: "milk"),
            NoteBlock(.todo(isDone: true), text: "bread"),
        ])
        XCTAssertEqual(NoteRendering.document(from: NoteRendering.text(for: document)).plainText,
                       "Shopping\nmilk\nbread")
    }

    // MARK: - Structure

    func testReturnInAListItemChangesStructure() {
        let before = NoteDocument(blocks: [NoteBlock(.bulleted, text: "onetwo")])
        var typed = NoteRendering.text(for: before)
        let marker = NoteRendering.marker(for: NoteBlock(.bulleted))
        typed.characters.insert(contentsOf: "\n",
                                at: typed.index(typed.startIndex,
                                                offsetByCharacters: marker.count + 3))
        let after = NoteRendering.document(from: typed)
        XCTAssertEqual(after.blocks.map(\.plainText), ["one", "two"])
        XCTAssertFalse(after.hasSameStructure(as: before))
    }

    func testTypingInsideAParagraphIsNotAStructuralChange() {
        let before = NoteDocument(blocks: [NoteBlock(.paragraph, text: "hello")])
        let after = NoteDocument(blocks: [NoteBlock(.paragraph, text: "hello there")])
        XCTAssertTrue(after.hasSameStructure(as: before))
    }

    func testAChangedKindIsAStructuralChange() {
        let before = NoteDocument(blocks: [NoteBlock(.paragraph, text: "x")])
        let after = NoteDocument(blocks: [NoteBlock(.bulleted, text: "x")])
        XCTAssertFalse(after.hasSameStructure(as: before))
    }

    // MARK: - Caret

    private func assertCaretSurvivesRedraw(_ document: NoteDocument,
                                           noteOffset: Int,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) {
        let text = NoteRendering.text(for: document)
        let index = NoteRendering.index(atNoteOffset: noteOffset, in: text)
        XCTAssertEqual(NoteRendering.noteOffset(of: index, in: text), noteOffset,
                       file: file, line: line)
    }

    func testCaretOffsetIsCountedInTheNotesOwnCharacters() {
        // Markers sit in front of the text, so a caret two characters into a
        // list item is at note offset 2 however wide its bullet is.
        let document = NoteDocument(blocks: [
            NoteBlock(.bulleted, text: "milk"),
            NoteBlock(.todo(isDone: true), text: "bread"),
        ])
        for offset in 0...document.plainText.count {
            assertCaretSurvivesRedraw(document, noteOffset: offset)
        }
    }

    func testCaretLandsAfterTheMarkerNotBeforeIt() {
        let document = NoteDocument(blocks: [NoteBlock(.bulleted, text: "milk")])
        let text = NoteRendering.text(for: document)
        let index = NoteRendering.index(atNoteOffset: 0, in: text)
        let marker = NoteRendering.marker(for: NoteBlock(.bulleted))
        XCTAssertEqual(text.characters.distance(from: text.startIndex, to: index), marker.count)
    }

    func testCaretSurvivesAMarkerAppearingInFrontOfIt() {
        // A paragraph becoming a list item: the same note offset has to come
        // back pointing at the same character, not shifted by the new bullet.
        let plain = NoteDocument(blocks: [NoteBlock(.paragraph, text: "milk")])
        let listed = NoteDocument(blocks: [NoteBlock(.bulleted, text: "milk")])
        let before = NoteRendering.text(for: plain)
        let caret = NoteRendering.index(atNoteOffset: 2, in: before)
        XCTAssertEqual(NoteRendering.noteOffset(of: caret, in: before), 2)

        let after = NoteRendering.text(for: listed)
        let moved = NoteRendering.index(atNoteOffset: 2, in: after)
        XCTAssertEqual(String(after[moved...].characters), "lk")
    }

    // MARK: - Indent

    func testIndentIsDrawnInFrontOfTheMarkerAndShedAgain() {
        let document = NoteDocument(blocks: [NoteBlock(.bulleted, indent: 2, text: "nested")])
        let text = NoteRendering.text(for: document)
        XCTAssertTrue(String(text.characters).hasPrefix(NoteRendering.indentation
            + NoteRendering.indentation + "\u{2022} "))
        XCTAssertEqual(NoteRendering.document(from: text), document)
    }

    func testCaretSurvivesAnIndentChangingUnderIt() {
        let shallow = NoteDocument(blocks: [NoteBlock(.bulleted, text: "milk")])
        let deep = NoteDocument(blocks: [NoteBlock(.bulleted, indent: 3, text: "milk")])
        let drawn = NoteRendering.text(for: shallow)
        let caret = NoteRendering.index(atNoteOffset: 2, in: drawn)
        XCTAssertEqual(NoteRendering.noteOffset(of: caret, in: drawn), 2)

        let redrawn = NoteRendering.text(for: deep)
        let moved = NoteRendering.index(atNoteOffset: 2, in: redrawn)
        XCTAssertEqual(String(redrawn[moved...].characters), "lk")
    }

    // MARK: - Blocks and offsets

    func testEachOffsetLandsInItsOwnBlock() {
        let document = NoteDocument(blocks: [
            NoteBlock(.heading(level: 1), text: "Title"),
            NoteBlock(.bulleted, text: "milk"),
            NoteBlock(.paragraph, text: "note"),
        ])
        // "Title" is 0...5, the boundary offset belonging to the line it ends.
        XCTAssertEqual(NoteRendering.blockPosition(atNoteOffset: 0, in: document), 0)
        XCTAssertEqual(NoteRendering.blockPosition(atNoteOffset: 5, in: document), 0)
        XCTAssertEqual(NoteRendering.blockPosition(atNoteOffset: 6, in: document), 1)
        XCTAssertEqual(NoteRendering.blockPosition(atNoteOffset: 11, in: document), 2)
        XCTAssertEqual(NoteRendering.blockPosition(atNoteOffset: 999, in: document), 2)
    }

    func testABlockStartsWhereItsOffsetSaysItDoes() {
        let document = NoteDocument(blocks: [
            NoteBlock(.paragraph, text: "one"),
            NoteBlock(.paragraph, text: "two"),
        ])
        let start = NoteRendering.noteOffset(ofBlockAt: 1, in: document)
        XCTAssertEqual(NoteRendering.blockPosition(atNoteOffset: start, in: document), 1)

        let drawn = NoteRendering.text(for: document)
        let caret = NoteRendering.index(atNoteOffset: start, in: drawn)
        XCTAssertEqual(String(drawn[caret...].characters), "two")
    }

    func testCaretLandsAfterTheMarkerOfABlockJustAutoformatted() throws {
        // What the editor does the moment "- " turns into a bullet: the typed
        // marker is gone and the drawn one must not swallow the caret.
        let formatted = NoteDocument(blocks: [NoteBlock(.paragraph, text: "- ")])
            .autoformatted(at: 0)
        let document = try XCTUnwrap(formatted)
        let drawn = NoteRendering.text(for: document)
        let caret = NoteRendering.index(
            atNoteOffset: NoteRendering.noteOffset(ofBlockAt: 0, in: document), in: drawn)
        XCTAssertEqual(caret, drawn.endIndex)
        XCTAssertEqual(String(drawn.characters), NoteRendering.marker(for: NoteBlock(.bulleted)))
    }

    // MARK: - Deleting into a marker

    func testBackspaceIntoABulletTakesTheBulletAwayRatherThanTheText() {
        // The marker is ordinary characters, so it can be deleted into. What
        // must not happen is the leftover bullet becoming the user's text.
        var text = NoteRendering.text(for: NoteDocument(blocks: [NoteBlock(.bulleted, text: "milk")]))
        let marker = NoteRendering.marker(for: NoteBlock(.bulleted))
        let caret = text.index(text.startIndex, offsetByCharacters: marker.count)
        text.characters.remove(at: text.index(caret, offsetByCharacters: -1))

        let document = NoteRendering.document(from: text)
        XCTAssertEqual(document.blocks.map(\.kind), [.paragraph])
        XCTAssertEqual(document.blocks.map(\.plainText), ["milk"])
    }

    func testBackspaceOnAnEmptyToDoLeavesAnEmptyParagraph() {
        var text = NoteRendering.text(for: NoteDocument(blocks: [NoteBlock(.todo(isDone: false))]))
        text.characters.removeLast()

        let document = NoteRendering.document(from: text)
        XCTAssertEqual(document.blocks.map(\.kind), [.paragraph])
        XCTAssertTrue(document.isEmpty)
    }

    func testBackspaceIntoTheBulletOfAnIndentedItemKeepsWhereItSat() {
        // The glyph goes, the indent does not: they are drawn separately and
        // a backspace only ever lands in one of them.
        var text = NoteRendering.text(for: NoteDocument(blocks: [
            NoteBlock(.bulleted, indent: 2, text: "nested"),
        ]))
        let marker = NoteRendering.marker(for: NoteBlock(.bulleted, indent: 2))
        text.characters.remove(at: text.index(text.startIndex,
                                              offsetByCharacters: marker.count - 1))

        let document = NoteRendering.document(from: text)
        XCTAssertEqual(document.blocks.map(\.kind), [.paragraph])
        XCTAssertEqual(document.blocks.map(\.indent), [2])
        XCTAssertEqual(document.blocks.map(\.plainText), ["nested"])
    }

    func testBackspaceInTheIndentOutdentsAndLeavesTheBulletAlone() {
        // The defect this guards: reading the indent and the bullet as one
        // marker stranded the bullet in the user's own text as literal
        // characters the moment a space in front of it went missing.
        var text = NoteRendering.text(for: NoteDocument(blocks: [
            NoteBlock(.bulleted, indent: 2, text: "nested"),
        ]))
        text.characters.remove(at: text.startIndex)

        let document = NoteRendering.document(from: text)
        XCTAssertEqual(document.blocks.map(\.kind), [.bulleted])
        XCTAssertEqual(document.blocks.map(\.indent), [1])
        XCTAssertEqual(document.blocks.map(\.plainText), ["nested"])
    }
}
