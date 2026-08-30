// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

/// A live widget, with its concrete type erased.
///
/// The shell places widgets it cannot name — the layout it renders is a list of
/// ids read off disk — so it holds them through this instead. One instance per
/// placed widget, kept for as long as the widget stays on the panel, which is
/// what gives a widget somewhere to keep its state between openings.
@MainActor
public final class WidgetInstance: Identifiable {
    public let descriptor: WidgetDescriptor
    public var id: WidgetID { descriptor.id }

    private let content: () -> AnyView
    private let start: () -> Void
    private let stop: () -> Void

    init<W: CCPWidget>(_ widget: W) {
        descriptor = W.descriptor
        content = { AnyView(widget.makeView()) }
        start = { widget.activate() }
        stop = { widget.deactivate() }
    }

    public var view: AnyView { content() }

    public func activate() { start() }
    public func deactivate() { stop() }
}
