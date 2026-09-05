// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import XCTest
@testable import CCPUI

/// The main menu is never drawn, so nothing on screen can prove it is right.
/// These assertions are the only thing standing between the app and silently
/// losing ⌘C again.
@MainActor
final class ApplicationMenuTests: XCTestCase {
    private var edit: NSMenu {
        get throws {
            let main = ApplicationMenu.standard(applicationName: "Test")
            let item = try XCTUnwrap(main.items.first(where: { $0.submenu?.title == "Edit" }))
            return try XCTUnwrap(item.submenu)
        }
    }

    func testEditMenuCarriesTheStandardShortcuts() throws {
        let shortcuts = try edit.items.reduce(into: [String: String]()) { result, item in
            guard let action = item.action else { return }
            result[NSStringFromSelector(action)] = item.keyEquivalent
        }
        XCTAssertEqual(shortcuts["cut:"], "x")
        XCTAssertEqual(shortcuts["copy:"], "c")
        XCTAssertEqual(shortcuts["paste:"], "v")
        XCTAssertEqual(shortcuts["selectAll:"], "a")
        XCTAssertEqual(shortcuts["undo:"], "z")
        XCTAssertEqual(shortcuts["redo:"], "z")
        XCTAssertNotNil(shortcuts["delete:"])
    }

    /// Undo and redo share ⌘Z; only the modifier tells them apart, so a missing
    /// mask makes redo unreachable and undo ambiguous.
    func testRedoIsShiftedOffUndo() throws {
        let redo = try XCTUnwrap(edit.items.first(where: { $0.action == Selector(("redo:")) }))
        XCTAssertEqual(redo.keyEquivalentModifierMask, [.command, .shift])
    }

    func testApplicationMenuQuitsAndOffersServices() throws {
        let main = ApplicationMenu.standard(applicationName: "Test")
        let app = try XCTUnwrap(main.items.first?.submenu)
        XCTAssertNotNil(app.items.first(where: { $0.action == #selector(NSApplication.terminate(_:)) }))
        let services = try XCTUnwrap(app.items.first(where: { $0.title == ApplicationMenu.servicesTitle }))
        XCTAssertNotNil(services.submenu)
    }
}
