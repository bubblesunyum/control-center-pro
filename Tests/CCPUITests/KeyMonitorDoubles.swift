// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import XCTest
@testable import CCPUI

/// Shared doubles for the key-watching monitors' tests (return and delete):
/// the same seam, the same proof. Promoted out of the return tests when the
/// delete tests became their second user.
@MainActor
final class RecordingTextView: NSTextView {
    struct Insertion: Equatable {
        var text: String
        var range: NSRange
    }

    private(set) var insertions: [Insertion] = []

    /// A windowless `NSTextView` silently drops `insertText`, which would
    /// make every splice assertion pass against an unchanged string — the
    /// double records the call AND performs it, so the tests prove the
    /// arguments as well as the decision.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = string as? String else { return }
        insertions.append(Insertion(text: text, range: replacementRange))
        self.string = (self.string as NSString).replacingCharacters(in: replacementRange, with: text)
        setSelectedRange(NSRange(location: replacementRange.location + (text as NSString).length,
                                 length: 0))
    }
}

/// Stands in for `NSEvent`'s local-monitor API with keys the test builds —
/// modifiers included, which the dismissal fake never needed.
@MainActor
final class FakeKeyMonitors {
    private(set) var added = 0
    private(set) var removed = 0
    private var live: Set<Int> = []
    private var handler: ((NSEvent) -> NSEvent?)?

    var installed: Int { live.count }

    var interface: EventMonitors {
        EventMonitors(
            addGlobal: { _, _ in nil },
            addLocal: { [self] _, handler in
                self.handler = handler
                return token()
            },
            remove: { [self] handle in
                guard let handle = handle as? Int else { return XCTFail("not one of ours") }
                live.remove(handle)
                removed += 1
            }
        )
    }

    private func token() -> Any {
        added += 1
        live.insert(added)
        return added
    }

    @discardableResult
    func send(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
        return handler?(event)
    }
}
