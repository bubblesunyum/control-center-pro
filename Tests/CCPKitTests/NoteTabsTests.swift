// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

/// Tabs vs docs: the X hides, the trash deletes. Hiding keeps the doc — text,
/// order and selection neighbours — and the hidden set survives a relaunch
/// under its own key, leaving the upstream-shared bytes alone.
@MainActor
final class NoteTabsTests: XCTestCase {
    private func store() throws -> (UserDefaults, String) {
        let name = "ccp.notetabs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    private func adapter(_ defaults: UserDefaults) -> NotesAdapter {
        NotesAdapter(defaults: defaults, defaultName: "Note")
    }

    /// Three notes, selected in the middle, texts A/B/C.
    private func three(_ adapter: NotesAdapter) throws -> [UUID] {
        let first = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = "text A"
        adapter.createNote()
        let second = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = "text B"
        adapter.createNote()
        let third = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = "text C"
        adapter.selectNote(second)
        return [first, second, third]
    }

    func testCloseTabHidesButKeepsTheDoc() throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)
        let ids = try three(adapter)

        XCTAssertTrue(adapter.closeTab(ids[1]))
        XCTAssertEqual(adapter.openNotes.map(\.id), [ids[0], ids[2]])
        XCTAssertEqual(adapter.closedNotes.map(\.id), [ids[1]])
        XCTAssertEqual(adapter.notes.count, 3, "hiding removes no doc")
        XCTAssertEqual(adapter.notes.first(where: { $0.id == ids[1] })?.text, "text B")
    }

    func testCloseTabMovesSelectionToTheNextOpenNeighbour() throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)
        let ids = try three(adapter)

        XCTAssertTrue(adapter.closeTab(ids[1]))
        XCTAssertEqual(adapter.selectedNoteID, ids[2])
    }

    func testCloseTabAtTheEndFallsBackToThePreviousNeighbour() throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)
        let ids = try three(adapter)
        adapter.selectNote(ids[2])

        XCTAssertTrue(adapter.closeTab(ids[2]))
        XCTAssertEqual(adapter.selectedNoteID, ids[1])
    }

    func testClosingLastOpenTabMintsFreshNote() throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)
        let ids = try three(adapter)

        XCTAssertTrue(adapter.closeTab(ids[0]))
        XCTAssertTrue(adapter.closeTab(ids[1]))
        // One tab left open: hiding it mints a fresh blank note first, so the
        // strip never empties and nothing hidden resurrects.
        XCTAssertTrue(adapter.closeTab(ids[2]))
        let fresh = try XCTUnwrap(adapter.selectedNoteID)
        XCTAssertFalse(ids.contains(fresh))
        XCTAssertEqual(adapter.openNotes.map(\.id), [fresh])
        XCTAssertEqual(adapter.notes.first(where: { $0.id == fresh })?.text, "")
        XCTAssertEqual(adapter.closedNotes.map(\.id), ids)
        XCTAssertEqual(adapter.restorableClosedNotes.map(\.id), ids)
        XCTAssertFalse(adapter.closeTab(UUID()), "unknown ids close nothing")
    }

    func testReopenTabBringsItBackAndShowsIt() throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)
        let ids = try three(adapter)

        XCTAssertTrue(adapter.closeTab(ids[0]))
        XCTAssertTrue(adapter.reopenTab(ids[0]))
        XCTAssertEqual(adapter.openNotes.map(\.id), ids)
        XCTAssertEqual(adapter.selectedNoteID, ids[0])
        XCTAssertTrue(adapter.closedNotes.isEmpty)
        XCTAssertTrue(adapter.reopenTab(ids[0]), "reopening an open tab is a harmless no-op")
    }

    func testHiddenSelectedTabHealsOnLoad() throws {
        // A torn write or a foreign edit of the shared document can strand
        // the selection hidden. The keys are a stable contract, like "pads".
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let ids = try three(adapter(defaults))

        // The stuck state itself, as a foreign write would leave it.
        let seeded = NotesDocument(
            notes: ids.enumerated().map { Note(id: $0.element, name: "N\($0.offset)", text: "") },
            selectedID: ids[1])
        defaults.set(try JSONEncoder().encode(seeded), forKey: "scratchpadDocument")
        defaults.set(try JSONEncoder().encode(Set([ids[1]])), forKey: "scratchpadClosedTabs")

        let healed = adapter(defaults)
        XCTAssertEqual(healed.selectedNoteID, ids[1])
        XCTAssertTrue(healed.closedNotes.isEmpty, "loading unhides the selection")
        XCTAssertEqual(healed.openNotes.map(\.id), ids)
    }

    func testSelectNoteUnhides() throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)
        let ids = try three(adapter)

        XCTAssertTrue(adapter.closeTab(ids[2]))
        adapter.selectNote(ids[2])
        XCTAssertEqual(adapter.selectedNoteID, ids[2])
        XCTAssertTrue(adapter.closedNotes.isEmpty, "selecting shows")
    }

    func testDeleteNoteDropsTheClosedID() throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)
        let ids = try three(adapter)

        XCTAssertTrue(adapter.closeTab(ids[2]))
        XCTAssertTrue(adapter.deleteNote(ids[2]))
        XCTAssertEqual(adapter.notes.map(\.id), [ids[0], ids[1]])
        XCTAssertTrue(adapter.closedNotes.isEmpty)
    }

    func testDeleteSelectedFallsBackToOpenNeighbour() throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)
        let ids = try three(adapter)
        adapter.selectNote(ids[1])

        XCTAssertTrue(adapter.closeTab(ids[2]))
        // The document-order fallback hid: selection yields to the nearest
        // open neighbour instead of resurrecting the hidden tab.
        XCTAssertTrue(adapter.deleteNote(ids[1]))
        XCTAssertEqual(adapter.selectedNoteID, ids[0])
        XCTAssertEqual(adapter.openNotes.map(\.id), [ids[0]])
        XCTAssertEqual(adapter.closedNotes.map(\.id), [ids[2]])
    }

    func testDeleteLastOpenTabMintsFreshNote() throws {
        // The reported bug: type in A, close A, delete the selected empty B —
        // B died but hidden A reopened in its place. Now a fresh blank note
        // opens and A stays hidden.
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)
        let typed = try XCTUnwrap(adapter.selectedNoteID)
        adapter.text = "typed words"
        adapter.createNote()
        let empty = try XCTUnwrap(adapter.selectedNoteID)

        XCTAssertTrue(adapter.closeTab(typed))
        XCTAssertTrue(adapter.deleteNote(empty))
        let fresh = try XCTUnwrap(adapter.selectedNoteID)
        XCTAssertNotEqual(fresh, typed)
        XCTAssertEqual(adapter.notes.map(\.id), [typed, fresh])
        XCTAssertEqual(adapter.notes.first(where: { $0.id == fresh })?.text, "")
        XCTAssertEqual(adapter.openNotes.map(\.id), [fresh])
        XCTAssertEqual(adapter.closedNotes.map(\.id), [typed])
    }

    func testClosedTabsPersistAcrossLaunches() throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = adapter(defaults)
        let ids = try three(first)
        XCTAssertTrue(first.closeTab(ids[0]))

        let second = adapter(defaults)
        XCTAssertEqual(second.closedNotes.map(\.id), [ids[0]])
        XCTAssertEqual(second.openNotes.map(\.id), [ids[1], ids[2]])
    }

    func testCloseTabDeletesEmptyNotes() throws {
        // Hiding an empty tab would strand it outside the restorable menu
        // while leaking a slot, so the X deletes it instead — identical from
        // the user's side, confirmation-free while empty.
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)
        let ids = try three(adapter)

        adapter.createNote()
        let empty = try XCTUnwrap(adapter.selectedNoteID)
        XCTAssertTrue(adapter.closeTab(empty))
        XCTAssertEqual(adapter.notes.map(\.id), ids)
        XCTAssertEqual(adapter.selectedNoteID, ids[2])
        XCTAssertTrue(adapter.closedNotes.isEmpty)
    }

    func testCloseSoleEmptyTabResetsBlank() throws {
        // The only tab, and blank: deletion refuses the last doc, so closing
        // resets — fresh blank in place of the dismissed one.
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)
        let sole = try XCTUnwrap(adapter.selectedNoteID)

        XCTAssertTrue(adapter.closeTab(sole))
        let fresh = try XCTUnwrap(adapter.selectedNoteID)
        XCTAssertNotEqual(fresh, sole)
        XCTAssertEqual(adapter.notes.map(\.id), [fresh])
        XCTAssertEqual(adapter.openNotes.map(\.id), [fresh])
    }

    func testCloseLastTabRefusedAtFullHouse() throws {
        // Twelve notes, eleven hidden, one open: minting the replacement is
        // impossible, so the close refuses — the X dims, the trash is the way
        // out.
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)
        var ids = [try XCTUnwrap(adapter.selectedNoteID)]
        adapter.text = "filler"
        for number in 1..<NotesDocument.maximumNoteCount {
            adapter.createNote()
            let id = try XCTUnwrap(adapter.selectedNoteID)
            adapter.text = "filler \(number)"
            ids.append(id)
        }
        XCTAssertEqual(adapter.notes.count, NotesDocument.maximumNoteCount)
        for id in ids.dropLast() {
            XCTAssertTrue(adapter.closeTab(id))
        }

        let last = try XCTUnwrap(ids.last)
        XCTAssertFalse(adapter.canCloseTab(last))
        XCTAssertFalse(adapter.closeTab(last))
        XCTAssertEqual(adapter.openNotes.map(\.id), [last])

        // An empty sole tab still closes: deletion frees its slot, so no
        // mint is needed and the X stays live.
        adapter.text = ""
        XCTAssertTrue(adapter.canCloseTab(last))
        XCTAssertTrue(adapter.closeTab(last))
        let replacement = try XCTUnwrap(adapter.selectedNoteID)
        XCTAssertNotEqual(replacement, last)
        XCTAssertEqual(adapter.openNotes.map(\.id), [replacement])
    }

    func testCraftDocumentURLMatchesTheVendorTemplate() {
        let url = NotesAdapter.craftDocumentURL(spaceID: "space-1", blockID: "doc-2")
        XCTAssertEqual(url?.absoluteString, "craftdocs://open?spaceId=space-1&blockId=doc-2")
    }

    func testPullCachesTheSpaceIDForDeepLinks() async throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)
        adapter.craftBaseURLOverride = URL(string: "https://connect.craft.do/links/test/api/v1")!
        adapter.craftTransport = ScriptedTransport([.init(statusCode: 200, json: """
            {"space":{"id":"space-9","name":"Test"},"utc":{"time":"2026-09-06T19:00:00Z"}}
            """)])

        XCTAssertNil(adapter.craftSpaceID)
        await adapter.pullAll()
        XCTAssertEqual(adapter.craftSpaceID, "space-9")
    }

    func testCredentialChangeClearsTheSpaceID() async throws {
        let (defaults, name) = try store()
        defer { defaults.removePersistentDomain(forName: name) }
        let adapter = adapter(defaults)
        adapter.craftBaseURLOverride = URL(string: "https://connect.craft.do/links/test/api/v1")!
        adapter.craftTransport = ScriptedTransport([.init(statusCode: 200, json: """
            {"space":{"id":"space-9","name":"Test"},"utc":{"time":"2026-09-06T19:00:00Z"}}
            """)])
        await adapter.pullAll()
        XCTAssertEqual(adapter.craftSpaceID, "space-9")

        NotificationCenter.default.post(name: .craftCredentialDidChange, object: nil)
        XCTAssertNil(adapter.craftSpaceID, "forget must not leave a stale deep-link address")
    }
}
