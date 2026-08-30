// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Observation

/// The arrangement as it currently stands: live widgets in lanes, and the
/// stored layout that describes them.
///
/// `PanelLayout` is the names on disk and `LaneSlot` is what a lane draws; this
/// is the one object that holds both and keeps them saying the same thing. It
/// exists because two separate things need exactly that pairing — starting and
/// stopping the widgets that are placed, and rearranging them — and neither is
/// the panel window's business or the file's.
@MainActor
@Observable
public final class PanelArrangement {
    public private(set) var layout: PanelLayout
    public private(set) var lanes: [[LaneSlot]]

    @ObservationIgnored private let registry: WidgetRegistry

    /// Whether the widgets are currently sampling. Held because activation is
    /// idempotent: the panel can be shown twice without the second one
    /// stacking a second timer inside every widget.
    @ObservationIgnored private var isActive = false

    public init(_ layout: PanelLayout, registry: WidgetRegistry) {
        let normalized = layout.normalized()
        self.registry = registry
        self.layout = normalized
        lanes = registry.resolve(normalized)
    }

    /// Every live widget on the panel, in no particular order — the slots that
    /// only stand in for an absent one have nothing to start.
    private var widgets: [WidgetInstance] {
        lanes.flatMap { $0 }.compactMap(\.instance)
    }

    /// Start sampling. The panel is on screen.
    public func activate() {
        guard !isActive else { return }
        isActive = true
        widgets.forEach { $0.activate() }
    }

    /// Stop sampling. With the panel shut the app's job is to cost nothing,
    /// and a widget still holding a timer is the only way it could cost
    /// something.
    public func deactivate() {
        guard isActive else { return }
        isActive = false
        widgets.forEach { $0.deactivate() }
    }
}
