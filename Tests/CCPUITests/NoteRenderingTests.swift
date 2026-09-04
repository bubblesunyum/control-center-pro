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
        let marker = NoteRendering.marker(for: .bulleted)
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
        let marker = NoteRendering.marker(for: .bulleted)
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
        let marker = NoteRendering.marker(for: .bulleted)
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
}
