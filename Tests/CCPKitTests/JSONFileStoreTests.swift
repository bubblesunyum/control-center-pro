// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

final class JSONFileStoreTests: XCTestCase {
    private let fallback = PanelLayout([["fallback"]])

    func testRoundTripsThroughTheFile() throws {
        let store = temporaryStore(default: fallback)
        let layout = PanelLayout([["a", "b"], ["c"]])

        try store.save(layout)

        XCTAssertEqual(store.load(), layout)
    }

    func testSavingCreatesTheDirectory() throws {
        let store = temporaryStore(default: fallback)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))

        try store.save(fallback)

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testNoFileYetIsTheDefault() {
        XCTAssertEqual(temporaryStore(default: fallback).load(), fallback)
    }

    func testUnreadableFileIsTheDefault() throws {
        let store = temporaryStore(default: fallback)
        try write("{ this is not the layout }", forStore: store)

        XCTAssertEqual(store.load(), fallback)
    }

    func testUnreadableFileIsMovedAsideRatherThanOverwritten() throws {
        let store = temporaryStore(default: fallback)
        try write("{ this is not the layout }", forStore: store)

        _ = store.load()

        let spoiled = store.url.appendingPathExtension("corrupt")
        XCTAssertEqual(
            try String(contentsOf: spoiled, encoding: .utf8),
            "{ this is not the layout }",
            "the file that could not be read is kept, so the reset can be explained"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.url.path),
            "and it is out of the way, so the next save is not a second failure"
        )
    }

    func testASecondUnreadableFileReplacesTheFirstSetAside() throws {
        let store = temporaryStore(default: fallback)
        try write("first", forStore: store)
        _ = store.load()
        try write("second", forStore: store)
        _ = store.load()

        XCTAssertEqual(
            try String(contentsOf: store.url.appendingPathExtension("corrupt"), encoding: .utf8),
            "second"
        )
    }
}
