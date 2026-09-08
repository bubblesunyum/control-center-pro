// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

/// Whether the panel is on screen, for the views inside it.
///
/// The panel hides with `orderOut` and keeps its SwiftUI graph standing — the
/// open is on a 100ms budget and rebuilding the graph is what that budget
/// cannot afford. So `onDisappear` never fires, hover never exits, and
/// anything a view pushed on its way in — a cursor, a hold timer, an
/// in-flight gesture's transients — outlives the panel it belonged to.
/// Widgets answer this with `deactivate()`; a view answers it with
/// ``SwiftUI/View/onPanelHidden(perform:)``.
@MainActor
@Observable
final class PanelVisibility {
    private(set) var isVisible = false

    func show() { isVisible = true }
    func hide() { isVisible = false }
}

private struct PanelVisibilityKey: EnvironmentKey {
    static let defaultValue: PanelVisibility? = nil
}

extension EnvironmentValues {
    var panelVisibility: PanelVisibility? {
        get { self[PanelVisibilityKey.self] }
        set { self[PanelVisibilityKey.self] = newValue }
    }
}

extension View {
    /// Tear down what this view is holding when the panel goes away — hidden
    /// with the graph intact, or genuinely dismantled. Both arrive here, so a
    /// view says its cleanup once instead of guessing which one it will get.
    ///
    /// A hide can be followed by a real teardown, so the action runs more than
    /// once for the same going-away: write it to say what should now be true
    /// rather than what should happen.
    func onPanelHidden(perform action: @escaping () -> Void) -> some View {
        modifier(PanelHiddenModifier(action: action))
    }
}

private struct PanelHiddenModifier: ViewModifier {
    @Environment(\.panelVisibility) private var visibility
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            // Outside the panel — a preview, a test host — there is nothing to
            // hide, so the standing value is "visible" and only a real
            // teardown fires.
            .onChange(of: visibility?.isVisible ?? true) { _, isVisible in
                if !isVisible { action() }
            }
            .onDisappear(perform: action)
    }
}
