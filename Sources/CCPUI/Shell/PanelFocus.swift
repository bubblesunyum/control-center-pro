// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import SwiftUI

/// Who the panel's keystrokes belong to.
///
/// Neither the Notes widget nor any sticky can say it directly: the editor
/// is an AppKit text view behind a SwiftUI wrapper, and SwiftUI focus stops
/// at that boundary. So each editor reports its own text view on arrival
/// (see `MarkdownNoteEditor.onCreate`) and the controller reads back
/// out the one outlet it needs: Notes on every open, a newborn sticky once.
@MainActor
@Observable
final class PanelFocus {
    /// The Notes editor's text view, while the widget is in the layout.
    /// Weak: removing the widget tears its view down and the outlet clears
    /// itself, which is how "Notes isn't here" reads as nil.
    weak var notesTextView: NSTextView?

    /// The sticky that should take focus when its view arrives. Set by
    /// `newSticky()` before the card exists, answered and cleared by the
    /// card itself. Nil the rest of the time: stickies never steal focus.
    var pendingStickyID: UUID?
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
