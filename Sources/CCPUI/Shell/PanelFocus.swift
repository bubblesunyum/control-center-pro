// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import SwiftUI
import WebKit

/// Who the panel's keystrokes belong to.
///
/// Neither the Notes widget nor any sticky can say it directly: the editor
/// is a web view behind a SwiftUI wrapper, and SwiftUI focus stops at that
/// boundary. So each editor reports its view on arrival and the controller
/// reads back out the one outlet it needs: Notes on every open, a newborn
/// sticky once.
@MainActor
@Observable
final class PanelFocus {
    /// The Notes editor's web view, once the widget has shown it. The view
    /// outlives the widget (one page per surface kind, loaded at launch), so
    /// "Notes isn't here" reads as the view being out of the panel window.
    weak var notesWebView: NSView?

    /// The sticky that should take focus when its view arrives. Set by
    /// `newSticky()` before the card exists, answered and cleared by the
    /// card itself. Nil the rest of the time: stickies never steal focus.
    var pendingStickyID: UUID?

    /// The panel window, set once by the controller. Held weakly: the
    /// controller owns the window, and focus only ever resigns through it.
    weak var panelWindow: NSWindow?

    /// Drops the caret from whatever editor holds it — a sticky's grab or
    /// resize press lands on SwiftUI chrome, never on the text view itself,
    /// so AppKit would otherwise leave the caret blinking mid-drag. No-op
    /// unless a text or web view holds first responder.
    func resignTextEditing() {
        guard let window = panelWindow,
              window.firstResponder is NSTextView || window.firstResponder is WKWebView
        else { return }
        window.makeFirstResponder(nil)
    }
}

private struct PanelFocusKey: EnvironmentKey {
    static let defaultValue: PanelFocus? = nil
}

extension EnvironmentValues {
    var panelFocus: PanelFocus? {
        get { self[PanelFocusKey.self] }
        set { self[PanelFocusKey.self] = newValue }
    }
}
