// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// How a lane flows its slots into rows.
///
/// A lane is a grid `units` columns wide, where one column is a lane unit and
/// the count comes from the widest span in the lane. Consecutive cards share a
/// row while their spans fit, so two 1x cards above a 2x Notes sit side by
/// side instead of each stretching to the lane's full width. A card alone in
/// its row still stretches to fill it — that is today's look, kept. An app
/// screen is not countable in lane units and always takes a row of its own at
/// the lane's full width.
extension LaneSlot {
    /// The grid columns this slot occupies, or `nil` when it is not countable
    /// in lane units and stands alone. An absent widget holds a 1x place.
    var gridColumns: Int? {
        switch self {
        case .widget(let widget, let span):
            widget.descriptor.size.isResizable ? span.width : nil
        case .unavailable:
            1
        }
    }

    /// The width this slot forces on its lane when it is not countable in
    /// grid columns — an app screen's own width — or `nil` when the grid
    /// counts it.
    var fixedWidth: CGFloat? {
        gridColumns == nil ? width : nil
    }
}

extension [LaneSlot] {
    /// The lane's grid width in columns: the widest countable span. An empty
    /// lane is one column until something says otherwise.
    var gridUnits: Int {
        compactMap(\.gridColumns).max() ?? 1
    }
}

extension Layout {
    /// How wide `units` grid columns are: the units plus the gutters between
    /// them. Gutters belong to the shell, not the cards — a 1x card is one
    /// lane unit wherever it sits, and the lane carries the `Space.oneHalf`
    /// between neighbours, the same step as between lanes and between stacked
    /// cards.
    static func gridWidth(units: Int) -> CGFloat {
        CGFloat(units) * laneWidth + CGFloat(max(units - 1, 0)) * Space.oneHalf
    }
}

/// Greedy flow of column counts into rows of `columns`.
///
/// A `nil` count is not countable in columns — an app screen — and always
/// stands alone. Anything wider than the row stands alone too, which is what a
/// card dragged in from a wider lane does until the lane re-counts around it.
/// Returns index rows, so the caller maps any cell type (slots, or slots with
/// the drop gap inserted) through the same packing the tests pin down.
func packRowIndexes(_ widths: [Int?], columns: Int) -> [[Int]] {
    var rows: [[Int]] = []
    var current: [Int] = []
    var remaining = columns
    func flush() {
        if !current.isEmpty { rows.append(current) }
        current = []
        remaining = columns
    }
    for (index, width) in widths.enumerated() {
        guard let width, width <= columns else {
            flush()
            rows.append([index])
            continue
        }
        if width > remaining { flush() }
        current.append(index)
        remaining -= width
        if remaining == 0 { flush() }
    }
    flush()
    return rows
}
