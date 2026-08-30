// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// Everything inside the glass: vertical lanes of widget cards.
///
/// The panel renders the slots it is handed and holds no opinion about how they
/// came to be — reading the arrangement off disk and resolving it against the
/// registry happens before this, and rearranging it is edit mode's business.
public struct ControlPanel: View {
    private let lanes: [[LaneSlot]]

    public init(lanes: [[LaneSlot]]) {
        self.lanes = lanes
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Space.oneHalf) {
            ForEach(lanes.indices, id: \.self) { index in
                WidgetLane(slots: lanes[index])
            }
        }
        .padding(Space.oneHalf)
    }
}

private struct WidgetLane: View {
    let slots: [LaneSlot]

    var body: some View {
        VStack(spacing: Space.oneHalf) {
            ForEach(slots) { slot in
                LaneSlotCard(slot: slot)
                    .frame(width: Layout.laneWidth)
                    .frame(minHeight: slot.height)
                    // Ideal height, then rigid: without this a lane's spare
                    // room is shared out among its cards and three widgets
                    // that each declared a different size come out the same.
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Lanes are as tall as the tallest of them, and without something
            // to absorb the slack a short lane hands it to its widgets instead
            // — three cards that each declared a different size come out the
            // same height.
            Spacer(minLength: 0)
        }
    }
}

private struct LaneSlotCard: View {
    let slot: LaneSlot

    var body: some View {
        switch slot {
        case .widget(let widget): widget.view
        case .unavailable(let id): UnavailableWidgetCard(id: id)
        }
    }
}

private extension LaneSlot {
    /// A slot standing in for a widget this build doesn't have has no
    /// descriptor to ask, and the smallest card is the least the lane's shape
    /// can be wrong by.
    var height: CGFloat {
        switch self {
        case .widget(let widget): widget.descriptor.size.height
        case .unavailable: WidgetSize.compact.height
        }
    }
}
