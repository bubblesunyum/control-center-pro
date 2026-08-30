// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// Everything inside the glass: vertical lanes of widget cards.
///
/// The panel renders the lanes it is handed and holds no opinion about how they
/// came to be — the layout model that reads them off disk and lets them be
/// rearranged lands in ccp-lr7.2 and ccp-lr7.6.
public struct ControlPanel: View {
    private let lanes: [[WidgetInstance]]

    public init(lanes: [[WidgetInstance]]) {
        self.lanes = lanes
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Space.oneHalf) {
            ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in
                WidgetLane(widgets: lane)
            }
        }
        .padding(Space.oneHalf)
    }
}

private struct WidgetLane: View {
    let widgets: [WidgetInstance]

    var body: some View {
        VStack(spacing: Space.oneHalf) {
            ForEach(widgets) { widget in
                widget.view
                    .frame(width: Layout.laneWidth)
                    .frame(minHeight: widget.descriptor.size.height)
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
