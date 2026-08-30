// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import XCTest
@testable import CCPKit

@MainActor
final class LayoutAutosaveTests: XCTestCase {
    private let a: WidgetID = "a"
    private let b: WidgetID = "b"

    /// A drag is dozens of mutations. Waiting is the whole point: none of them
    /// should reach the disk while the finger is still moving.
    func testItDoesNotWriteWhileChangesAreStillArriving() {
        let store = temporaryStore(default: PanelLayout.empty)
        let autosave = LayoutAutosave(store: store, delay: .seconds(30))

        autosave.schedule(PanelLayout([[a]]))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.url.path),
            "nothing has settled yet"
        )
    }

    func testTheLastLayoutIsTheOneWritten() {
        let store = temporaryStore(default: PanelLayout.empty)
        let autosave = LayoutAutosave(store: store, delay: .seconds(30))

        autosave.schedule(PanelLayout([[a]]))
        autosave.schedule(PanelLayout([[a, b]]))
        autosave.flush()

        XCTAssertEqual(store.load().lanes, [[a, b]])
    }

    func testItWritesOnceTheChangesStop() async throws {
        let store = temporaryStore(default: PanelLayout.empty)
        let autosave = LayoutAutosave(store: store, delay: .milliseconds(10))

        autosave.schedule(PanelLayout([[a]]))
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(store.load().lanes, [[a]])
    }

    func testFlushingWithNothingPendingIsFine() {
        let store = temporaryStore(default: PanelLayout.empty)
        let autosave = LayoutAutosave(store: store, delay: .milliseconds(10))

        autosave.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    /// Quitting during the debounce must not lose the edit, and flushing must
    /// not leave the timer behind to write the same thing again.
    func testFlushingCancelsThePendingWrite() async throws {
        let store = temporaryStore(default: PanelLayout.empty)
        let autosave = LayoutAutosave(store: store, delay: .milliseconds(10))

        autosave.schedule(PanelLayout([[a]]))
        autosave.flush()
        try FileManager.default.removeItem(at: store.url)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.url.path),
            "the cancelled write did not come back"
        )
    }
}
