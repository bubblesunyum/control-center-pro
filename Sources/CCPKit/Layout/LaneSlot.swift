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
    case widget(WidgetInstance, Placement)
    case unavailable(WidgetID)

    public var id: WidgetID {
        switch self {
        case .widget(let widget, _): widget.id
        case .unavailable(let id): id
        }
    }

    /// The size the user dragged this card to, or `nil` when it has never
    /// been resized. An absent widget has nothing to resize.
    public var customSize: CustomWidgetSize? {
        switch self {
        case .widget(_, let placement): placement.customSize
        case .unavailable: nil
        }
    }

    /// The live widget here, or `nil` where the slot is only holding a name's
    /// place. Anything done to the widgets on the panel — starting them,
    /// stopping them — is done to these.
    public var instance: WidgetInstance? {
        switch self {
        case .widget(let widget, _): widget
        case .unavailable: nil
        }
    }
}

public extension WidgetRegistry {
    /// The layout as live widgets, one slot per stored placement.
    func resolve(_ layout: PanelLayout) -> [[LaneSlot]] {
        layout.lanes.map { lane in
            lane.map { placement in
                let id = placement.id
                return makeInstance(of: id).map { LaneSlot.widget($0, placement) } ?? .unavailable(id)
            }
        }
    }
}
