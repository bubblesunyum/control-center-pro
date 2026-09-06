// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import CCPKit

/// Clipboard rows, Finder files and browser text all land in the selected
/// note through `acceptDrop`, appended behind a blank line. Images have no
/// text form and spring back unaccepted.
@MainActor
final class NotesDropTests: XCTestCase {
    private func store() throws -> (UserDefaults, String) {
        let name = "ccp.notesdrop.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    private func adapter(_ defaults: UserDefaults, text: String = "") -> NotesAdapter {
        let adapter = NotesAdapter(defaults: defaults, defaultName: "Note")
        adapter.text = text
        return adapter
    }

    private func textProvider(_ string: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerObject(string as NSString, visibility: .all)
        return provider
    }

    private func fileProvider(_ path: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerObject(URL(fileURLWithPath: path) as NSURL, visibility: .all)
        return provider
    }

    // MARK: - Appending

    func testAppendToEmptyNoteTakesFragmentAsIs() throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)

        adapter.appendDroppedText("  hello  ")

        XCTAssertEqual(adapter.text, "hello")
    }

    func testAppendSeparatesWithBlankLine() throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults, text: "existing")

        adapter.appendDroppedText("dropped")

        XCTAssertEqual(adapter.text, "existing\n\ndropped")
    }

    func testAppendAfterTrailingNewlineKeepsOneBlankLine() throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults, text: "existing\n")

        adapter.appendDroppedText("dropped")

        XCTAssertEqual(adapter.text, "existing\n\ndropped")
    }

    func testAppendIgnoresBlankFragment() throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults, text: "existing")

        adapter.appendDroppedText("  \n ")

        XCTAssertEqual(adapter.text, "existing")
    }

    // MARK: - Providers

    func testAcceptDropAppendsText() async throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults, text: "note")

        XCTAssertTrue(adapter.acceptDrop(providers: [textProvider("clip")]))
        let arrived = await becomesTrue { adapter.text == "note\n\nclip" }
        XCTAssertTrue(arrived, "dropped text never landed in the note")
    }

    func testAcceptDropAppendsFilePath() async throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)

        XCTAssertTrue(adapter.acceptDrop(providers: [fileProvider("/tmp/receipt.pdf")]))
        let arrived = await becomesTrue { adapter.text == "/tmp/receipt.pdf" }
        XCTAssertTrue(arrived, "dropped file path never landed in the note")
    }

    func testAcceptDropAppendsLinkAddress() async throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)
        let provider = NSItemProvider()
        provider.registerObject(URL(string: "https://example.com/p")! as NSURL, visibility: .all)

        XCTAssertTrue(adapter.acceptDrop(providers: [provider]))
        let arrived = await becomesTrue { adapter.text == "https://example.com/p" }
        XCTAssertTrue(arrived, "dropped link never landed in the note")
    }

    func testAcceptDropDeclinesImageOnly() throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults, text: "note")
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier,
                                            visibility: .all) { completion in
            completion(Data([0x89, 0x50]), nil)
            return nil
        }

        XCTAssertFalse(adapter.acceptDrop(providers: [provider]))
        XCTAssertEqual(adapter.text, "note")
    }

    func testAcceptDropDeclinesEmptyProviders() throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)

        XCTAssertFalse(adapter.acceptDrop(providers: []))
        XCTAssertTrue(adapter.text.isEmpty)
    }

    // MARK: - Drag payload

    func testPlainTextMapping() {
        XCTAssertEqual(ClipboardEntry(text: "hello").plainText, "hello")
        XCTAssertEqual(
            ClipboardEntry(text: "", kind: .files, filePaths: ["/a.txt", "/b.txt"]).plainText,
            "/a.txt\n/b.txt")
        XCTAssertNil(ClipboardEntry(text: "", kind: .image, imageFile: "x.png").plainText)
        XCTAssertNil(ClipboardEntry(text: "", kind: .files).plainText)
    }

    // MARK: - Shelf shim

    /// Shelf text/link rows dual-register a temp-file URL beside their real
    /// text. The note must take the content, not a rotting /tmp path.
    func testAcceptDropPrefersTextOverTempFileShim() async throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)
        let shim = FileManager.default.temporaryDirectory
            .appendingPathComponent("call mom-\(UUID().uuidString).txt")
        let provider = NSItemProvider()
        provider.registerObject(shim as NSURL, visibility: .all)
        provider.registerObject("call mom" as NSString, visibility: .all)

        XCTAssertTrue(adapter.acceptDrop(providers: [provider]))
        let arrived = await becomesTrue { adapter.text == "call mom" }
        XCTAssertTrue(arrived, "shelf shim landed as a temp path instead of its text")
    }

    /// A real temp file with no text alongside still lands as its path —
    /// the shim rule only fires when text is offered too.
    func testAcceptDropKeepsRealTempFilePath() async throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("real-\(UUID().uuidString).txt").path

        XCTAssertTrue(adapter.acceptDrop(providers: [fileProvider(path)]))
        let arrived = await becomesTrue { adapter.text == path }
        XCTAssertTrue(arrived, "real temp file path never landed in the note")
    }

    // MARK: - Drop target

    /// A slow drop lands on the tab it was dropped on, even if the user
    /// has moved on before the loads finish.
    func testAppendTargetsDropTimeNote() throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)
        let first = try XCTUnwrap(adapter.selectedNoteID)
        adapter.createNote()
        let second = try XCTUnwrap(adapter.selectedNoteID)
        XCTAssertNotEqual(first, second)

        adapter.appendDroppedText("for first", to: first)

        XCTAssertEqual(adapter.selectedNoteID, second, "append moved the selection")
        XCTAssertEqual(adapter.notes.first(where: { $0.id == first })?.text, "for first")
        XCTAssertTrue(adapter.notes.first(where: { $0.id == second })?.text.isEmpty == true)
    }
}
