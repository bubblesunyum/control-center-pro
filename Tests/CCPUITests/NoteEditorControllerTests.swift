// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
@testable import CCPUI
import XCTest

/// The Swift half of the editor against the real bundled page: what the app
/// hands over loads, what the user types comes back with untouched blocks
/// kept byte for byte, and a replace from outside never overwrites typing.
@MainActor
final class NoteEditorControllerTests: XCTestCase {
    private var controller: NoteEditorController!
    private var window: NSWindow!

    override func setUp() async throws {
        controller = NoteEditorController(style: .notes)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                          styleMask: .borderless, backing: .buffered, defer: false)
        controller.webView.frame = window.contentView!.bounds
        window.contentView?.addSubview(controller.webView)
    }

    override func tearDown() async throws {
        controller.webView.removeFromSuperview()
        controller = nil
        window = nil
    }

    private func page(_ script: String) async throws -> Any? {
        try await controller.webView.callAsyncJavaScript(script, contentWorld: .page)
    }

    func testTypingKeepsEveryBlockTheUserDidNotTouch() async throws {
        let pad = "# Plan  \n*****  \n- parent  \n\t- child  \nlast"
        var saved: [String] = []
        await controller.show(documentId: "a", text: pad, onText: { saved.append($0) }).value

        _ = try await page("bbEditor.command('a', 'focus', 'end'); bbEditor.command('a', 'insertContent', '!')")
        try await waitUntil { !saved.isEmpty }

        // The rule and the tab-indented child keep their stored spelling;
        // only the edited block and the joins are the editor's.
        XCTAssertEqual(saved.last, "# Plan\n\n*****\n\n- parent\n\t- child\n\nlast!")
    }

    func testAReplaceFromOutsideShowsTheNewText() async throws {
        await controller.show(documentId: "a", text: "old", onText: { _ in }).value
        await controller.show(documentId: "a", text: "new  \ntext", onText: { _ in }).value
        try await waitUntil { (try? await self.page("return bbEditor.markdown('a')")) as? String == "new\n\ntext" }
    }

    func testAReplaceNeverOverwritesTyping() async throws {
        var saved: [String] = []
        await controller.show(documentId: "a", text: "old", onText: { saved.append($0) }).value
        // Typed in the page, and the app has not heard yet.
        _ = try await page("bbEditor.command('a', 'focus', 'end'); bbEditor.command('a', 'insertContent', ' typed')")
        controller.show(documentId: "a", text: "from a pull", onText: { saved.append($0) })
        try await waitUntil { saved.last == "old typed" }
        let shown = try await page("return bbEditor.markdown('a')") as? String
        XCTAssertEqual(shown, "old typed")
    }

    func testEmptyPageReportNeverWipesAppText() async throws {
        var saved: [String] = []
        await controller.show(documentId: "a", text: "one\n\ntwo\n\nthree",
                              onText: { saved.append($0) }).value
        let seededMarkdown = try await page("return bbEditor.markdown('a')") as? String
        let seeded = try XCTUnwrap(seededMarkdown)
        saved.removeAll()

        controller.receiveChange(documentId: "a", markdown: "")
        controller.receiveChange(documentId: "a", markdown: "one")
        XCTAssertTrue(saved.isEmpty)

        try await waitUntil { (try? await self.page("return bbEditor.markdown('a')")) as? String == seeded }
    }

    func testChangeBeforeOpenNeverAppliesPreOpenEmpty() async throws {
        var saved: [String] = []
        let opened = controller.show(documentId: "a", text: "hello", onText: { saved.append($0) })
        controller.receiveChange(documentId: "a", markdown: "")
        await opened.value

        XCTAssertFalse(saved.contains(""))
        controller.receiveChange(documentId: "a", markdown: "hello typed")
        XCTAssertEqual(saved.last, "hello typed")
    }

    func testSupersededOpenRetryExitsOnGenerationBump() async throws {
        let stale = controller.show(documentId: "a", text: "one", onText: { _ in })
        // A newer show supersedes before the first chain baselines: the
        // bump stands the stale chain down instead of doubling the opens.
        controller.show(documentId: "a", text: "two", onText: { _ in })
        await stale.value
        try await waitUntil { (try? await self.page("return bbEditor.markdown('a')")) as? String == "two" }
        XCTAssertFalse(controller.opening.contains("a"))
    }

    func testFocusedSelectionDeletePropagates() async throws {
        var saved: [String] = []
        await controller.show(documentId: "a", text: "one\n\ntwo\n\nthree",
                              onText: { saved.append($0) }).value
        saved.removeAll()

        // The headless test window never takes focus, so no page script can
        // produce a real selection message: simulate the focused page
        // through the same caret state the selection message would set.
        controller.caret = NoteEditorController.Caret(documentId: "a", midY: 0, headingLevel: 0)
        controller.receiveChange(documentId: "a", markdown: "")

        XCTAssertEqual(saved.last, "")
    }

    private func waitUntil(timeout: Duration = .seconds(10), _ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
