// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Carbon.HIToolbox
import XCTest
@testable import CCPKit

@MainActor
final class SettingsStoreTests: XCTestCase {
    private let shortcut = KeyCombination(keyCode: Int64(kVK_ANSI_C),
                                          modifiers: [.control, .option, .command])

    func testStartsWithNoShortcut() {
        XCTAssertNil(SettingsStore(file: settingsStore()).panelShortcut)
    }

    func testAChosenShortcutSurvivesTheStore() {
        let file = settingsStore()
        SettingsStore(file: file).panelShortcut = shortcut

        XCTAssertEqual(SettingsStore(file: file).panelShortcut, shortcut)
    }

    func testClearingTheShortcutSurvivesTheStore() {
        let file = settingsStore()
        let settings = SettingsStore(file: file)
        settings.panelShortcut = shortcut
        settings.panelShortcut = nil

        XCTAssertNil(SettingsStore(file: file).panelShortcut)
    }

    /// A build that stops recognising a stored combination should come up
    /// without one rather than not come up.
    func testAnUnreadableStoredShortcutIsNoShortcut() throws {
        let file = settingsStore()
        try file.save(StoredSettings(panelShortcut: "meta:9999999999"))

        XCTAssertNil(SettingsStore(file: file).panelShortcut)
    }

    private func settingsStore() -> JSONFileStore<StoredSettings> {
        temporaryStore(default: StoredSettings(), filename: "settings.json")
    }
}
