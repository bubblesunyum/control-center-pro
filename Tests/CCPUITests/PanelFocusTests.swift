// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPUI
import XCTest

/// Every panel open belongs to Notes — unless something else has a better
/// claim. These pin the policy: edit mode and the gallery own their own
/// keystrokes, a missing or read-only Notes takes nothing, and Notes
/// already holding focus keeps its caret where the user left it.
final class PanelFocusTests: XCTestCase {
    private func check(
        isEditing: Bool = false,
        galleryOpen: Bool = false,
        notesEditable: Bool = true,
        notesAlreadyFocused: Bool = false,
        newcomerPending: Bool = false,
        _ file: StaticString = #filePath,
        _ line: UInt = #line
    ) -> Bool {
        ControlPanelController.shouldAutofocusNotes(
            isEditing: isEditing,
            galleryOpen: galleryOpen,
            notesEditable: notesEditable,
            notesAlreadyFocused: notesAlreadyFocused,
            newcomerPending: newcomerPending
        )
    }

    func testPlainOpenFocusesNotes() {
        XCTAssertTrue(check())
    }

    func testEditModeKeepsFocus() {
        XCTAssertFalse(check(isEditing: true))
    }

    func testGalleryKeepsFocus() {
        XCTAssertFalse(check(galleryOpen: true))
    }

    func testUnreadableNotesTakesNothing() {
        XCTAssertFalse(check(notesEditable: false))
    }

    func testFocusedNotesKeepsItsCaret() {
        XCTAssertFalse(check(notesAlreadyFocused: true))
    }

    /// A newborn sticky is on its way: the open leaves focus alone so its
    /// arrival claims it, instead of flashing through Notes first (and
    /// yanking Notes' caret to the end on the way).
    func testNewcomerSuppressesNotesClaim() {
        XCTAssertFalse(check(newcomerPending: true))
    }
}
