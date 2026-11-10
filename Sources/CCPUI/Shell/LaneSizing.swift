// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// How big a card in a lane is, and so how wide its lane is.
///
/// One rule: a card the user has resized is exactly the size they dragged
/// it to; a card they never touched fills its lane at its natural height. A
/// lane is as wide as the widest card in it. There is no grid, no step, and
/// no per-widget floor or ceiling — the only limit is the display, which
/// `Layout.fittedLaneWidths` enforces for the panel as a whole.
extension LaneSlot {
    /// The size the user gave this card, or `nil` when it was never resized.
    ///
    /// A layout from before free resizing stored a span instead, and such a
    /// card keeps the points that span used to draw until it is dragged
    /// again — the file is the user's, and their arrangement should open
    /// looking the way they left it.
    var storedSize: CGSize? {
        guard case .widget(let widget, let placement) = self else { return nil }
        if let size = placement.customSize {
            return CGSize(width: size.width, height: size.height)
        }
        guard placement.span != .unit, widget.descriptor.size != .screen else { return nil }
        let columns = CGFloat(placement.span.width)
        return CGSize(
            width: columns * Layout.laneWidth + (columns - 1) * Space.oneHalf,
            height: CGFloat(placement.span.height) * widget.descriptor.size.height
        )
    }

    /// How wide a card that was never resized asks its lane to be.
    var defaultWidth: CGFloat {
        switch self {
        case .widget(let widget, _): widget.descriptor.size.width
        case .unavailable: Layout.laneWidth
        }
    }

    /// How tall a card that was never resized stands at least; its content
    /// may ask for more and gets it.
    var defaultHeight: CGFloat {
        switch self {
        case .widget(let widget, _): widget.descriptor.size.height
        case .unavailable: WidgetSize.compact.height
        }
    }

    /// The width this card claims of its lane.
    var width: CGFloat { storedSize?.width ?? defaultWidth }

    /// What to call this in a label — the widget's own name, or the id, which
    /// is all a slot standing in for an absent widget has.
    var title: String {
        switch self {
        case .widget(let widget, _): widget.descriptor.title
        case .unavailable(let id): id.rawValue
        }
    }
}

@MainActor
extension [LaneSlot] {
    /// How wide a lane holding these is: its widest card. An empty lane is a
    /// lane of cards until something says otherwise.
    var width: CGFloat {
        map { $0.width }.max() ?? Layout.laneWidth
    }
}

extension PanelArrangement {
    /// Every lane's width, in order, as stored — what edit mode measures the
    /// room for a resize or one more column against.
    var laneWidths: [CGFloat] { lanes.map(\.width) }
}
