// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

/// One tool on the panel.
///
/// A widget owns its own state and its own view, and knows nothing about lanes,
/// the panel, or its neighbours. Adding a tool to Control Center Pro means
/// writing a conformer and naming it in the registry the app composes at
/// launch — the shell is untouched.
@MainActor
public protocol CCPWidget: AnyObject, Identifiable {
    /// What this widget is, independent of where it sits. Static because a
    /// gallery has to describe a widget it has not instantiated.
    static var descriptor: WidgetDescriptor { get }

    init()

    associatedtype Content: View
    /// The widget as it appears in its lane.
    @ViewBuilder func makeView() -> Content

    /// Start sampling. Called when the panel opens.
    func activate()
    /// Stop sampling. Called when the panel closes — with the panel shut, the
    /// app's job is to cost nothing.
    func deactivate()
}

public extension CCPWidget {
    var id: WidgetID { Self.descriptor.id }
    var descriptor: WidgetDescriptor { Self.descriptor }

    /// A widget that only reflects state it is handed has nothing to start or
    /// stop, and shouldn't have to say so.
    func activate() {}
    func deactivate() {}
}
