// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

/// One position in a lane, resolved against the registry.
///
/// A layout can name a widget this build doesn't have — one from a newer
/// version, or from before a rename. Dropping it would leave the lane a slot
/// shorter with nothing to explain the change, so the position survives as
/// `unavailable` and the shell draws it. The id is still in the file either
/// way; this only says whether we could make something of it.
@MainActor
public enum LaneSlot: Identifiable {
    case widget(WidgetInstance)
    case unavailable(WidgetID)

    public var id: WidgetID {
        switch self {
        case .widget(let widget): widget.id
        case .unavailable(let id): id
        }
    }
}

public extension WidgetRegistry {
    /// The layout as live widgets, one slot per stored id.
    func resolve(_ layout: PanelLayout) -> [[LaneSlot]] {
        layout.lanes.map { lane in
            lane.map { id in
                makeInstance(of: id).map(LaneSlot.widget) ?? .unavailable(id)
            }
        }
    }
}
