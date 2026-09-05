// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPKit

/// The Notes document's bytes are shared with upstream's floating pad and are
/// the only copy of anything the user wrote. These are the tests that would
/// have caught the rename eating them.
@MainActor
final class NotesDocumentStorageTests: XCTestCase {
    private let padID = UUID(uuidString: "50642B4A-4533-43DF-BD75-282FC55E7286")!

    private func storedJSON(key: String) -> Data {
        Data("""
        {"\(key)":[{"text":"kept","id":"\(padID.uuidString)","name":"Scratchpad"}],
         "selectedID":"\(padID.uuidString)"}
        """.utf8)
    }

    func testDecodesUpstreamsPadsKey() throws {
        let document = try XCTUnwrap(NotesDocument.decoded(storedJSON(key: "pads"), defaultName: "Note"))
        XCTAssertEqual(document.notes.map(\.text), ["kept"])
        XCTAssertEqual(document.selectedID, padID)
    }

    /// One build wrote the Swift property name into the file.
    func testDecodesTheNotesKeyOneBuildWrote() throws {
        let document = try XCTUnwrap(NotesDocument.decoded(storedJSON(key: "notes"), defaultName: "Note"))
        XCTAssertEqual(document.notes.map(\.text), ["kept"])
    }

    func testEncodesBackToPadsSoUpstreamStillReadsIt() throws {
        let document = try XCTUnwrap(NotesDocument.decoded(storedJSON(key: "pads"), defaultName: "Note"))
        let encoded = try XCTUnwrap(document.encoded())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["pads"], "the stored key must stay pads")
        XCTAssertNil(object["notes"])
    }

    // MARK: The adapter's side

    private func defaults(_ name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testUnreadableDocumentIsNeverWrittenOverOnLoad() throws {
        let name = "ccp.notes.unreadable.\(UUID().uuidString)"
        let store = try defaults(name)
        let garbage = Data("{\"this\":\"is not a document\"}".utf8)
        store.set(garbage, forKey: "scratchpadDocument")

        _ = NotesAdapter(defaults: store, defaultName: "Note")

        XCTAssertEqual(store.data(forKey: "scratchpadDocument"), garbage,
                       "loading must not replace bytes it could not read")
        store.removePersistentDomain(forName: name)
    }

    /// The close that follows an unreadable load flushes like any other, and a
    /// flush used to write the empty stand-in over the live key.
    func testClosingThePanelWithoutEditingWritesNothing() throws {
        let name = "ccp.notes.noedit.\(UUID().uuidString)"
        let store = try defaults(name)
        let garbage = Data("{\"this\":\"is not a document\"}".utf8)
        store.set(garbage, forKey: "scratchpadDocument")

        let adapter = NotesAdapter(defaults: store, defaultName: "Note")
        adapter.activate()
        adapter.deactivate()

        XCTAssertEqual(store.data(forKey: "scratchpadDocument"), garbage,
                       "an open and close with no edit must leave the bytes alone")
        XCTAssertNil(store.data(forKey: "scratchpadDocument.unreadable"),
                     "and must not have needed the rescue key at all")
        store.removePersistentDomain(forName: name)
    }

    /// A backup nothing reads back is not a recovery path.
    func testARescuedDocumentIsReadBackWhenThisBuildCanDecodeIt() throws {
        let name = "ccp.notes.readback.\(UUID().uuidString)"
        let store = try defaults(name)
        store.set(Data("not a document".utf8), forKey: "scratchpadDocument")
        store.set(storedJSON(key: "pads"), forKey: "scratchpadDocument.unreadable")

        let adapter = NotesAdapter(defaults: store, defaultName: "Note")

        XCTAssertEqual(adapter.text, "kept", "the rescued notes come back")
        XCTAssertNil(store.data(forKey: "scratchpadDocument.unreadable"),
                     "and the rescue key is consumed, not left to shadow later edits")
        store.removePersistentDomain(forName: name)
    }

    func testTheFirstRealEditMovesUnreadableBytesAsideRatherThanOverThem() throws {
        let name = "ccp.notes.rescue.\(UUID().uuidString)"
        let store = try defaults(name)
        let garbage = Data("{\"this\":\"is not a document\"}".utf8)
        store.set(garbage, forKey: "scratchpadDocument")

        let adapter = NotesAdapter(defaults: store, defaultName: "Note")
        adapter.text = "something new"
        adapter.deactivate()

        XCTAssertEqual(store.data(forKey: "scratchpadDocument.unreadable"), garbage,
                       "the unreadable document is kept under its own key")
        XCTAssertNotEqual(store.data(forKey: "scratchpadDocument"), garbage,
                          "and the new note is saved normally")
        store.removePersistentDomain(forName: name)
    }
}
