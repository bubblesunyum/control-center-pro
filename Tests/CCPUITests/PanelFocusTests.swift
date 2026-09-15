// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
@testable import CCPUI
import XCTest

/// Every panel open belongs to Notes — unless something else has a better
/// claim. These pin the policy: edit mode and the gallery own their own
/// keystrokes, a missing Notes takes nothing, and Notes
/// already holding focus keeps its caret where the user left it.
final class PanelFocusTests: XCTestCase {
    private func check(
        isEditing: Bool = false,
        galleryOpen: Bool = false,
        notesAlreadyFocused: Bool = false,
        newcomerPending: Bool = false,
        _ file: StaticString = #filePath,
        _ line: UInt = #line
    ) -> Bool {
        ControlPanelController.shouldAutofocusNotes(
            isEditing: isEditing,
            galleryOpen: galleryOpen,
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

    func testFocusedNotesKeepsItsCaret() {
        XCTAssertFalse(check(notesAlreadyFocused: true))
    }

    /// A newborn sticky is on its way: the open leaves focus alone so its
    /// arrival claims it, instead of flashing through Notes first (and
    /// yanking Notes' caret to the end on the way).
    func testNewcomerSuppressesNotesClaim() {
        XCTAssertFalse(check(newcomerPending: true))
    }

    /// Grabbing a sticky's padding or resize grip steps the caret down: the
    /// press lands on SwiftUI chrome AppKit never sees, so without an
    /// explicit resign the text view would keep first responder mid-drag.
    @MainActor
    func testResignNoopsWithoutWindow() {
        let focus = PanelFocus()
        focus.resignTextEditing()
    }

    @MainActor
    func testResignClearsTextFirstResponder() {
        let focus = PanelFocus()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(textView)
        focus.panelWindow = window

        XCTAssertTrue(window.makeFirstResponder(textView))
        XCTAssertTrue(window.firstResponder is NSTextView)

        focus.resignTextEditing()

        XCTAssertFalse(window.firstResponder is NSTextView)
    }

    @MainActor
    func testResignLeavesNonTextResponderAlone() {
        let focus = PanelFocus()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let button = NSButton(frame: window.contentView!.bounds)
        window.contentView?.addSubview(button)
        focus.panelWindow = window

        guard window.makeFirstResponder(button) else {
            focus.resignTextEditing()
            XCTAssertFalse(window.firstResponder is NSTextView)
            return
        }

        focus.resignTextEditing()

        XCTAssertTrue(window.firstResponder === button)
    }
}
