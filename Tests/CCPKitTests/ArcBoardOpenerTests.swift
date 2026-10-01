// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import Foundation
import XCTest

final class ArcBoardOpenerTests: XCTestCase {
    private func board(_ string: String) -> URL { URL(string: string)! }

    // Test-only mutable capture behind a lock: the @Sendable closures below
    // run off the test thread, so shared state goes through NSLock.
    private final class ScriptSpy: @unchecked Sendable {
        private let lock = NSLock()
        let running: Bool
        let tabs: [String]
        let focusResult: Bool
        private var _listed = false
        private var _focused: [String] = []

        var listed: Bool { lock.withLock { _listed } }
        var focused: [String] { lock.withLock { _focused } }

        init(running: Bool, tabs: [String] = [], focusResult: Bool = true) {
            self.running = running
            self.tabs = tabs
            self.focusResult = focusResult
        }

        func opener() -> LiveArcBoardOpener {
            LiveArcBoardOpener(
                isArcRunning: { self.running },
                listTabURLs: { self.lock.withLock { self._listed = true }; return self.tabs },
                focusTab: { url in self.lock.withLock { self._focused.append(url) }; return self.focusResult })
        }
    }

    // MARK: - matchesArcTab

    func testMatchesSamePort() {
        XCTAssertTrue(LiveArcBoardOpener.matchesArcTab(
            tabURL: "http://localhost:7393/", boardURL: board("http://localhost:7393/")))
    }

    func testRejectsDifferentPort() {
        XCTAssertFalse(LiveArcBoardOpener.matchesArcTab(
            tabURL: "http://localhost:7394/", boardURL: board("http://localhost:7393/")))
    }

    func testRejectsPortPrefix() {
        // 7393 is a string prefix of 73930, not the same port.
        XCTAssertFalse(LiveArcBoardOpener.matchesArcTab(
            tabURL: "http://localhost:73930/", boardURL: board("http://localhost:7393/")))
    }

    func testMatches127VersusLocalhost() {
        XCTAssertTrue(LiveArcBoardOpener.matchesArcTab(
            tabURL: "http://127.0.0.1:7393/", boardURL: board("http://localhost:7393/")))
        XCTAssertTrue(LiveArcBoardOpener.matchesArcTab(
            tabURL: "http://localhost:7393/", boardURL: board("http://127.0.0.1:7393/")))
    }

    func testToleratesPathAndQuery() {
        XCTAssertTrue(LiveArcBoardOpener.matchesArcTab(
            tabURL: "http://localhost:7393/some/path?x=1&y=2", boardURL: board("http://localhost:7393/")))
        XCTAssertTrue(LiveArcBoardOpener.matchesArcTab(
            tabURL: "http://localhost:7393/", boardURL: board("http://localhost:7393/index.html?fresh=1")))
        XCTAssertTrue(LiveArcBoardOpener.matchesArcTab(
            tabURL: "http://localhost:7393/?x=1", boardURL: board("http://localhost:7393/")))
    }

    func testRejectsNonHTTP() {
        XCTAssertFalse(LiveArcBoardOpener.matchesArcTab(
            tabURL: "ftp://localhost:7393/", boardURL: board("http://localhost:7393/")))
        XCTAssertFalse(LiveArcBoardOpener.matchesArcTab(
            tabURL: "about:blank", boardURL: board("http://localhost:7393/")))
        XCTAssertFalse(LiveArcBoardOpener.matchesArcTab(
            tabURL: "file:///tmp/board.html", boardURL: board("http://localhost:7393/")))
        XCTAssertFalse(LiveArcBoardOpener.matchesArcTab(
            tabURL: "http://localhost:7393/", boardURL: board("ftp://localhost:7393/")))
    }

    func testRejectsSchemeMismatch() {
        // An https error page at the same port must not shadow the http board.
        XCTAssertFalse(LiveArcBoardOpener.matchesArcTab(
            tabURL: "https://localhost:7393/", boardURL: board("http://localhost:7393/")))
        XCTAssertFalse(LiveArcBoardOpener.matchesArcTab(
            tabURL: "http://localhost:7393/", boardURL: board("https://localhost:7393/")))
    }

    func testRejectsNonLoopbackHost() {
        XCTAssertFalse(LiveArcBoardOpener.matchesArcTab(
            tabURL: "http://example.com:7393/", boardURL: board("http://localhost:7393/")))
        XCTAssertFalse(LiveArcBoardOpener.matchesArcTab(
            tabURL: "http://localhost:7393/", boardURL: board("http://example.com:7393/")))
    }

    func testRejectsMissingPortAndGarbage() {
        XCTAssertFalse(LiveArcBoardOpener.matchesArcTab(
            tabURL: "http://localhost/", boardURL: board("http://localhost:7393/")))
        XCTAssertFalse(LiveArcBoardOpener.matchesArcTab(
            tabURL: "not a url", boardURL: board("http://localhost:7393/")))
        XCTAssertFalse(LiveArcBoardOpener.matchesArcTab(
            tabURL: "", boardURL: board("http://localhost:7393/")))
    }

    // MARK: - AppleScript escaping

    func testEscapesQuotesAndBackslashes() {
        XCTAssertEqual(LiveArcBoardOpener.appleScriptEscape(#"a"b\c"#), #"a\"b\\c"#)
        XCTAssertEqual(LiveArcBoardOpener.appleScriptEscape("plain"), "plain")
        XCTAssertEqual(LiveArcBoardOpener.appleScriptEscape(""), "")
    }

    func testFocusScriptEmbedsEscapedURL() {
        let raw = #"http://localhost:7393/?q=a"b\c"#
        let script = LiveArcBoardOpener.focusTabSource(tabURL: raw)
        XCTAssertTrue(script.contains(#"q=a\"b\\c"#))
        XCTAssertFalse(script.contains(raw))
        XCTAssertTrue(script.contains(#"tell application "Arc""#))
        XCTAssertTrue(script.contains("select tab"))
        XCTAssertTrue(script.contains("activate"))
        XCTAssertTrue(script.contains("set index of window wi to 1"))
    }

    // MARK: - openBoard

    func testArcAbsentReturnsFalseWithoutScripting() async {
        let spy = ScriptSpy(running: false, tabs: ["http://localhost:7393/"])
        let reused = await spy.opener().openBoard(board("http://localhost:7393/"))
        XCTAssertFalse(reused)
        XCTAssertFalse(spy.listed)
        XCTAssertTrue(spy.focused.isEmpty)
    }

    func testFocusesFirstMatchingTab() async {
        let spy = ScriptSpy(running: true, tabs: [
            "https://example.com/",
            "http://localhost:7394/",
            "http://127.0.0.1:7393/?x=1",
            "http://localhost:7393/other",
        ])
        let reused = await spy.opener().openBoard(board("http://localhost:7393/"))
        XCTAssertTrue(reused)
        XCTAssertTrue(spy.listed)
        XCTAssertEqual(spy.focused, ["http://127.0.0.1:7393/?x=1"])
    }

    func testReturnsFalseWhenNoTabMatches() async {
        let spy = ScriptSpy(running: true, tabs: ["https://example.com/", "http://localhost:9999/"])
        let noHit = await spy.opener().openBoard(board("http://localhost:7393/"))
        XCTAssertFalse(noHit)
        XCTAssertTrue(spy.listed)
        XCTAssertTrue(spy.focused.isEmpty)
    }

    func testCrossSchemeTabDoesNotReuse() async {
        // An https error page at the same port must not shadow the http
        // board: no focus, so the caller still falls back.
        let spy = ScriptSpy(running: true, tabs: ["https://localhost:7393/"])
        let reused = await spy.opener().openBoard(board("http://localhost:7393/"))
        XCTAssertFalse(reused)
        XCTAssertTrue(spy.focused.isEmpty)
    }

    func testReturnsFalseWhenFocusFails() async {
        let spy = ScriptSpy(running: true, tabs: ["http://localhost:7393/"], focusResult: false)
        let reused = await spy.opener().openBoard(board("http://localhost:7393/"))
        XCTAssertFalse(reused)
        XCTAssertEqual(spy.focused, ["http://localhost:7393/"])
    }

    func testUnmatchableBoardURLNeverScripts() async {
        let spy = ScriptSpy(running: true, tabs: ["http://localhost:7393/"])
        let reused = await spy.opener().openBoard(board("https://example.com:7393/"))
        XCTAssertFalse(reused)
        XCTAssertFalse(spy.listed)
        XCTAssertTrue(spy.focused.isEmpty)
    }
}
