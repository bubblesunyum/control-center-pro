// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
@testable import CCPUI
import XCTest

/// The edit-mode pill's contract: two buttons with distinct actions, and a
/// nonzero ideal size the status item can take its length from.
@MainActor
final class EditPillTests: XCTestCase {
    func testPillOffersDoneAndAdd() {
        let pill = EditPill(onDone: {}, onAdd: {}, onRightClick: {})

        XCTAssertEqual(pill.buttons.count, 2)
        XCTAssertNotNil(pill.button(label: "Done editing"))
        XCTAssertNotNil(pill.button(label: "Add widget"))
    }

    func testPressingDoneFiresDoneOnly() {
        var done = 0
        var added = 0
        let pill = EditPill(onDone: { done += 1 }, onAdd: { added += 1 }, onRightClick: {})

        // Direct dispatch, not performClick: that routes through NSApp, which
        // does not exist in a test process (it silently no-ops). The wiring —
        // target plus action reaching the closure — is what is ours to prove;
        // click-to-action is AppKit's.
        if let button = pill.button(label: "Done editing"), let action = button.action {
            button.target?.perform(action, with: button)
        }

        XCTAssertEqual(done, 1)
        XCTAssertEqual(added, 0)
    }

    func testPressingAddFiresAddOnly() {
        var done = 0
        var added = 0
        let pill = EditPill(onDone: { done += 1 }, onAdd: { added += 1 }, onRightClick: {})

        if let button = pill.button(label: "Add widget"), let action = button.action {
            button.target?.perform(action, with: button)
        }

        XCTAssertEqual(done, 0)
        XCTAssertEqual(added, 1)
    }

    func testPillHasNonzeroIdealSize() {
        let pill = EditPill(onDone: {}, onAdd: {}, onRightClick: {})

        XCTAssertGreaterThan(pill.fittingSize.width, 0)
        XCTAssertGreaterThan(pill.fittingSize.height, 0)
    }

    /// The pill keeps the bar's own contract: nothing painted behind the
    /// item, a native checkmark the bar tints, and a white plus on the pill's
    /// own accent well. Both glyphs must exist: an empty button is exactly
    /// the invisible-pill bug this guards against.
    func testPillUsesNativeMenuBarChrome() {
        let pill = EditPill(onDone: {}, onAdd: {}, onRightClick: {})

        XCTAssertNil(pill.layer?.backgroundColor, "no painted capsule")

        guard let add = pill.button(label: "Add widget"),
              let done = pill.button(label: "Done editing") else {
            XCTFail("both buttons"); return
        }
        XCTAssertNotNil(add.image, "add glyph exists")
        XCTAssertNotNil(done.image, "done glyph exists")
        XCTAssertTrue(add.image?.isTemplate == true, "tint applies to add glyph")
        XCTAssertTrue(done.image?.isTemplate == true, "bar tints the done glyph")
        XCTAssertNotNil(add.contentTintColor, "white holds on the accent well")
        XCTAssertNil(done.contentTintColor, "bar tints the done glyph")
    }

    /// Both glyphs are comfortably tappable, and the plus well stays a
    /// capsule — cramped targets are what used to answer Done for Add.
    func testTargetsAreGenerousAndWellIsCapsule() {
        let pill = EditPill(onDone: {}, onAdd: {}, onRightClick: {})
        pill.frame = CGRect(origin: .zero, size: pill.fittingSize)
        pill.layoutSubtreeIfNeeded()

        for button in pill.buttons {
            XCTAssertGreaterThanOrEqual(button.frame.width, 24)
            XCTAssertGreaterThanOrEqual(button.frame.height, 24)
        }
        let wells = pill.subviews.flatMap(\.subviews).filter { !($0 is NSButton) && $0 !== pill }
        XCTAssertEqual(wells.count, 1)
        wells.first.map { XCTAssertEqual($0.layer?.cornerRadius, $0.bounds.height / 2) }
    }
    /// finish, the same as the status button's own background.
    func testBackgroundClickFinishesEditing() {
        var done = 0
        let pill = EditPill(onDone: { done += 1 }, onAdd: {}, onRightClick: {})
        pill.frame = CGRect(origin: .zero, size: pill.fittingSize)
        pill.layoutSubtreeIfNeeded()

        // The leading inset: inside the pill, on no button.
        XCTAssertNotNil(pill.hitTest(NSPoint(x: 2, y: pill.bounds.midY)))
        XCTAssertFalse(pill.hitTest(NSPoint(x: 2, y: pill.bounds.midY)) is NSButton)
        pill.mouseDown(with: mouse(.leftMouseDown))

        XCTAssertEqual(done, 1)
    }

    /// The buttons keep their own presses: hit-testing still finds them under
    /// the background rule.
    func testButtonsStillReceiveTheirOwnClicks() {
        let pill = EditPill(onDone: {}, onAdd: {}, onRightClick: {})
        pill.frame = CGRect(origin: .zero, size: pill.fittingSize)
        pill.layoutSubtreeIfNeeded()

        for button in pill.buttons {
            let center = pill.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
            XCTAssertTrue(pill.hitTest(center) === button)
        }
    }

    /// The Add capsule's own fill counts as Add: a press on the accent ring
    /// around the plus must not answer Done and exit edit mode (ccp-th8k).
    func testWellRingHitsAddButton() {
        let pill = EditPill(onDone: {}, onAdd: {}, onRightClick: {})
        pill.frame = CGRect(origin: .zero, size: pill.fittingSize)
        pill.layoutSubtreeIfNeeded()

        guard let add = pill.button(label: "Add widget"),
              let well = add.superview
        else {
            XCTFail("add button in its well"); return
        }
        // Inside the well's fill but off the button (leading inset is 7pt).
        let ringPoint = pill.convert(NSPoint(x: 2, y: well.bounds.midY), from: well)
        XCTAssertTrue(pill.hitTest(ringPoint) === add)
    }

    /// Right-click anywhere on the pill pops the status menu — the pill covers
    /// the button that used to own it, on the background and both controls.
    func testRightClickPopsMenuFromBackgroundAndButtons() {
        var menus = 0
        let pill = EditPill(onDone: {}, onAdd: {}, onRightClick: { menus += 1 })
        pill.frame = CGRect(origin: .zero, size: pill.fittingSize)
        pill.layoutSubtreeIfNeeded()

        pill.rightMouseDown(with: mouse(.rightMouseDown))
        for button in pill.buttons {
            button.rightMouseDown(with: mouse(.rightMouseDown))
        }

        XCTAssertEqual(menus, 1 + pill.buttons.count)
    }

    /// Ctrl-click keeps the status item's own contract on the pill: a menu,
    /// never Done or Add (ccp-kxfi).
    func testControlClickPopsMenuFromBackgroundAndButtons() {
        var done = 0
        var added = 0
        var menus = 0
        let pill = EditPill(onDone: { done += 1 }, onAdd: { added += 1 }, onRightClick: { menus += 1 })
        pill.frame = CGRect(origin: .zero, size: pill.fittingSize)
        pill.layoutSubtreeIfNeeded()

        pill.mouseDown(with: mouse(.leftMouseDown, flags: .control))
        for button in pill.buttons {
            button.mouseDown(with: mouse(.leftMouseDown, flags: .control))
        }

        XCTAssertEqual(menus, 1 + pill.buttons.count)
        XCTAssertEqual(done, 0)
        XCTAssertEqual(added, 0)
    }

    private func mouse(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!
    }
}

private extension EditPill {
    var buttons: [NSButton] {
        var found: [NSButton] = []
        var stack: [NSView] = [self]
        while let view = stack.popLast() {
            if let button = view as? NSButton { found.append(button) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    func button(label: String) -> NSButton? {
        buttons.first { $0.accessibilityLabel() == label }
    }
}