// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import Foundation
import XCTest

/// Making a block into a heading, a list or a to-do — by typing the marker
/// markdown spends on it, or by asking for it outright.
final class NoteBlockCommandsTests: XCTestCase {
    // MARK: - Autoformatting

    func testTypedMarkersBecomeTheBlockTheyName() {
        let expected: [(String, NoteBlock.Kind)] = [
            ("# ", .heading(level: 1)),
            ("### ", .heading(level: 3)),
            ("- ", .bulleted),
            ("* ", .bulleted),
            ("+ ", .bulleted),
            ("1. ", .numbered),
            ("42. ", .numbered),
            ("[] ", .todo(isDone: false)),
            ("[ ] ", .todo(isDone: false)),
            ("[x] ", .todo(isDone: true)),
            ("> ", .quote),
            ("``` ", .code(language: nil)),
        ]
        for (typed, kind) in expected {
            let formatted = NoteDocument(blocks: [NoteBlock(.paragraph, text: typed)])
                .autoformatted(at: 0)
            XCTAssertEqual(formatted?.blocks.map(\.kind), [kind], "typing \(typed)")
            XCTAssertEqual(formatted?.blocks.map(\.plainText), [""], "typing \(typed)")
        }
    }

    func testAMarkerInFrontOfExistingProseIsLeftAlone() {
        // Firing here would rewrite a paragraph someone was only editing the
        // front of, and there is no way to take an autoformat back.
        let document = NoteDocument(blocks: [NoteBlock(.paragraph, text: "- shopping list")])
        XCTAssertNil(document.autoformatted(at: 0))
    }

    func testAMarkerTypedInsideAListIsJustText() {
        let document = NoteDocument(blocks: [NoteBlock(.bulleted, text: "- ")])
        XCTAssertNil(document.autoformatted(at: 0))
    }

    func testHeadingBeyondTheDeepestLevelIsNotAMarker() {
        let document = NoteDocument(blocks: [NoteBlock(.paragraph, text: "####### ")])
        XCTAssertNil(document.autoformatted(at: 0))
    }

    func testOnlyTheBlockTheCaretIsInIsAutoformatted() {
        // The defect this guards: a "- " sitting untouched in another
        // paragraph would convert itself the next time anything at all was
        // typed, and take the caret across the note with it.
        let document = NoteDocument(blocks: [
            NoteBlock(.paragraph, text: "- "),
            NoteBlock(.paragraph, text: "Groceries"),
        ])
        XCTAssertNil(document.autoformatted(at: 1))
        XCTAssertEqual(document.autoformatted(at: 0)?.blocks.map(\.kind),
                       [.bulleted, .paragraph])
    }

    func testAutoformattingOutsideTheDocumentIsNothing() {
        XCTAssertNil(NoteDocument.blank.autoformatted(at: 7))
    }

    func testAutoformattingIsSettledInOnePass() {
        // A converted block no longer carries its marker, so nothing is left
        // for a second pass to find — which is what lets the editor run this
        // on every keystroke.
        let once = NoteDocument(blocks: [NoteBlock(.paragraph, text: "- ")]).autoformatted(at: 0)
        XCTAssertNil(once?.autoformatted(at: 0))
    }

    func testTypedMarkerKeepsTheStylingOfTextAfterIt() {
        let block = NoteBlock(.paragraph, inlines: [NoteInline("- ")])
        let formatted = NoteDocument(blocks: [block]).autoformatted(at: 0)
        XCTAssertEqual(formatted?.blocks[0].inlines.count, 0)
    }

    // MARK: - Block kind commands

    func testKindAppliesToEveryBlockTheSelectionTouches() {
        let document = NoteDocument(blocks: [
            NoteBlock(.paragraph, text: "one"),
            NoteBlock(.paragraph, text: "two"),
            NoteBlock(.paragraph, text: "three"),
        ]).togglingKind(.bulleted, forBlocksAt: 0..<2)
        XCTAssertEqual(document.blocks.map(\.kind), [.bulleted, .bulleted, .paragraph])
    }

    func testChoosingTheKindYouAreAlreadyInReturnsToAParagraph() {
        let document = NoteDocument(blocks: [NoteBlock(.heading(level: 2), text: "Title")])
        XCTAssertEqual(document.togglingKind(.heading(level: 2), forBlocksAt: 0..<1).blocks[0].kind,
                       .paragraph)
    }

    func testAMixedSelectionTakesTheKindRatherThanClearingIt() {
        let document = NoteDocument(blocks: [
            NoteBlock(.bulleted, text: "one"),
            NoteBlock(.paragraph, text: "two"),
        ]).togglingKind(.bulleted, forBlocksAt: 0..<2)
        XCTAssertEqual(document.blocks.map(\.kind), [.bulleted, .bulleted])
    }

    func testATickedToDoIsStillTheKindItIs() {
        // Otherwise the menu loses its checkmark the moment a box is ticked,
        // and choosing To-do again would make a fresh unticked one.
        let document = NoteDocument(blocks: [NoteBlock(.todo(isDone: true), text: "milk")])
        XCTAssertTrue(document.blocks(at: 0..<1, allAre: .todo(isDone: false)))
        XCTAssertEqual(document.togglingKind(.todo(isDone: false), forBlocksAt: 0..<1).blocks[0].kind,
                       .paragraph)
    }

    func testHeadingLevelsAreDifferentKinds() {
        let document = NoteDocument(blocks: [NoteBlock(.heading(level: 1), text: "Title")])
        XCTAssertFalse(document.blocks(at: 0..<1, allAre: .heading(level: 2)))
        XCTAssertEqual(document.togglingKind(.heading(level: 2), forBlocksAt: 0..<1).blocks[0].kind,
                       .heading(level: 2))
    }

    func testCommandsOutsideTheDocumentChangeNothing() {
        let document = NoteDocument(blocks: [NoteBlock(.paragraph, text: "one")])
        XCTAssertEqual(document.togglingKind(.bulleted, forBlocksAt: 3..<9), document)
        XCTAssertEqual(document.indentingBlocks(at: 3..<9, by: 1), document)
        XCTAssertFalse(document.blocks(at: 3..<9, allAre: .paragraph))
        XCTAssertNil(document.indentRange(atBlocks: 3..<9))
    }

    // MARK: - Indent

    func testIndentAndOutdentMoveTheBlocksTheSelectionTouches() {
        let document = NoteDocument(blocks: [
            NoteBlock(.bulleted, text: "one"),
            NoteBlock(.bulleted, indent: 1, text: "two"),
        ])
        XCTAssertEqual(document.indentingBlocks(at: 0..<2, by: 1).blocks.map(\.indent), [1, 2])
        XCTAssertEqual(document.indentingBlocks(at: 0..<2, by: -1).blocks.map(\.indent), [0, 0])
    }

    func testIndentStopsAtTheDeepestLevel() {
        let document = NoteDocument(blocks: [
            NoteBlock(.bulleted, indent: NoteBlock.maximumIndent, text: "deep"),
        ])
        XCTAssertEqual(document.indentingBlocks(at: 0..<1, by: 1).blocks[0].indent,
                       NoteBlock.maximumIndent)
    }

    func testIndentRangeSpansTheSelection() {
        let document = NoteDocument(blocks: [
            NoteBlock(.bulleted, text: "one"),
            NoteBlock(.bulleted, indent: 3, text: "two"),
        ])
        XCTAssertEqual(document.indentRange(atBlocks: 0..<2), 0...3)
    }
}
