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

    func testUnreadableFileSurvivesTheRead() throws {
        let store = temporaryStore(default: fallback)
        try write("{ this is not the layout }", forStore: store)

        XCTAssertEqual(store.load(), fallback)
        XCTAssertEqual(
            try String(contentsOf: store.url, encoding: .utf8),
            "{ this is not the layout }",
            "a read moves nothing aside — the evidence stays where it was"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.url.appendingPathExtension("corrupt").path
        ))
    }

    func testFirstSaveSetsUndecodableLiveFileAside() throws {
        let store = temporaryStore(default: fallback)
        try write("{ this is not the layout }", forStore: store)
        let layout = PanelLayout([["a"]])

        try store.save(layout)

        XCTAssertEqual(
            try String(contentsOf: store.url.appendingPathExtension("corrupt"), encoding: .utf8),
            "{ this is not the layout }",
            "the first deliberate write keeps the bytes it could not read"
        )
        XCTAssertEqual(store.load(), layout)
    }

    func testSetAsideIsOnceOnly() throws {
        let store = temporaryStore(default: fallback)
        try write("first", forStore: store)
        try store.save(fallback)
        try write("second", forStore: store)
        try store.save(fallback)

        XCTAssertEqual(
            try String(contentsOf: store.url.appendingPathExtension("corrupt"), encoding: .utf8),
            "first",
            "the first evidence is never overwritten by the second"
        )
        XCTAssertEqual(store.load(), fallback)
    }

    func testRescueReadBackAdoptsTheSetAside() throws {
        let store = temporaryStore(default: fallback)
        let layout = PanelLayout([["a", "b"], ["c"]])
        try write("{ this is not the layout }", forStore: store)
        try JSONEncoder().encode(layout).write(to: store.url.appendingPathExtension("corrupt"))

        XCTAssertEqual(
            store.load(), layout,
            "a set-aside that still decodes stands in for unreadable live bytes"
        )
        XCTAssertEqual(
            try String(contentsOf: store.url, encoding: .utf8),
            "{ this is not the layout }",
            "the recovery touches nothing — the next save re-commits it"
        )
    }

    func testMissingFileDoesNotResurrectASetAside() throws {
        let store = temporaryStore(default: fallback)
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(PanelLayout([["old"]]))
            .write(to: store.url.appendingPathExtension("corrupt"))

        XCTAssertEqual(
            store.load(), fallback,
            "a missing live file is a fresh start, not a resurrection"
        )
    }

    func testTolerantLoadSalvagesDecodableItems() throws {
        let store = temporaryStore(default: [String](), filename: "items.json")
        try write(#"["keep", 42, "also keep"]"#, forStore: store)

        let salvaged: [String] = store.tolerantLoad()

        XCTAssertEqual(salvaged, ["keep", "also keep"])
    }

    func testTolerantLoadWithNothingSalvageableLeavesTheFileAlone() throws {
        let store = temporaryStore(default: [String](), filename: "items.json")
        try write("[42, {}]", forStore: store)

        let salvaged: [String] = store.tolerantLoad()

        XCTAssertTrue(salvaged.isEmpty)
        XCTAssertEqual(try String(contentsOf: store.url, encoding: .utf8), "[42, {}]")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.url.appendingPathExtension("corrupt").path),
            "the next save sets it aside — the read must not"
        )
    }
}
