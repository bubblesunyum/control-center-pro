// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// Every gap and inset on the panel, as multiples of one 8pt unit.
///
/// A surface using 9, 12, 14 and 18 as gaps is four words for one idea, and the
/// eye tests every difference before discarding it. Reach for a step; a raw
/// number is a decision to justify.
public enum Space {
    public static let half: CGFloat = 4
    public static let one: CGFloat = 8
    public static let oneHalf: CGFloat = 12
    public static let two: CGFloat = 16
    public static let three: CGFloat = 24
}

/// The width of the glass vocabulary's lines.
public enum Stroke {
    /// The hairline around a card. One point, not one pixel — on a Retina
    /// display a 1px line is thinner than the system draws its own.
    public static let hairline: CGFloat = 1
}

/// The panel and its cards are a nested pair of rounded rectangles: the card
/// radius sits visibly inside the panel's rather than splitting the difference
/// with it.
public enum Radius {
    public static let card: CGFloat = 16
    public static let panel: CGFloat = 24
    /// Controls that sit inside a card — a toggle tile, a segmented row.
    public static let control: CGFloat = 10
}

/// How big the shell's boxes are.
///
/// A lane is a fixed width so the panel's growth is countable — one more lane
/// is one more column, not a reflow — and a widget's height comes from the size
/// it declares. `WidgetSize` names the intent; the points belong here.
public enum Layout {
    public static let laneWidth: CGFloat = 240
    /// How far the panel sits from the screen's top-right corner.
    public static let panelInset: CGFloat = Space.one
}

public extension WidgetSize {
    /// The height a widget of this size asks for. A widget whose content needs
    /// more gets it — the panel is sized from what it actually holds — so this
    /// is the floor that keeps a lane of small widgets from looking ragged.
    var height: CGFloat {
        switch self {
        case .compact: 64
        case .regular: 132
        case .tall: 232
        }
    }
}
