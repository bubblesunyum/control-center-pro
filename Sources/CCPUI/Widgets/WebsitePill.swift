// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

/// The website bar's hang: pure geometry, kept out of the view so the
/// corner×room matrix is provable without laying anything out.
struct WebsitePill {
    /// Which corner of a website card summoned its bar.
    enum Corner: Equatable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
    }

    /// One of the bar's four hangs: below or above, off the leading or
    /// trailing edge. Default bottom-leading.
    enum Placement {
        case belowLeading, belowTrailing, aboveLeading, aboveTrailing

        var alignment: Alignment {
            switch self {
            case .belowLeading: return .bottomLeading
            case .belowTrailing: return .bottomTrailing
            case .aboveLeading: return .topLeading
            case .aboveTrailing: return .topTrailing
            }
        }

        var xOffset: CGFloat {
            switch self {
            case .belowLeading, .aboveLeading: return Space.one
            case .belowTrailing, .aboveTrailing: return -Space.one
            }
        }

        var yOffset: CGFloat {
            switch self {
            case .belowLeading, .belowTrailing: return WebsitePill.barHeight
            case .aboveLeading, .aboveTrailing: return -WebsitePill.barHeight
            }
        }
    }

    /// The bar's size as drawn: buttons plus capsule padding, estimated for
    /// placement — the bar is hidden until the pointer is already near a
    /// corner, so it never reports its own size for where to hang.
    static let barWidth: CGFloat = 200
    static let barHeight: CGFloat = 44
    /// The corner proximity: how near the pointer must be to raise the bar.
    /// Wide enough to land, short enough that the rest of the page never
    /// triggers it. A hover threshold, not a view — nothing covers the page.
    static let proximityWidth: CGFloat = 120
    static let proximityHeight: CGFloat = 28

    /// Which corner the pointer summoned the bar from, from a hover location
    /// in card space. Nil away from every corner — hovering the middle of
    /// the page leaves the bar hidden.
    static func corner(at location: CGPoint, in size: CGSize) -> Corner? {
        let nearLeading = location.x < proximityWidth + Space.two
        let nearTrailing = location.x > size.width - proximityWidth - Space.two
        let nearTop = location.y < proximityHeight + Space.two
        let nearBottom = location.y > size.height - proximityHeight - Space.two
        switch (nearLeading, nearTrailing, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeading
        case (_, true, true, _): return .topTrailing
        case (true, _, _, true): return .bottomLeading
        case (_, true, _, true): return .bottomTrailing
        default: return nil
        }
    }

    /// Where the bar hangs for the summoning corner: off that corner's side,
    /// flipped vertically when the hang would leave the display, and onto
    /// the trailing side when the bar is wider than the card — hanging right
    /// past a right-seated panel is off screen by construction (the panel
    /// sits 8pt from it), while hanging left always has desktop. A keyboard
    /// summon (nil) hangs below until the display says otherwise.
    static func placement(
        for corner: Corner?,
        cardWidth: CGFloat,
        barWidth: CGFloat = WebsitePill.barWidth,
        roomAbove: Bool,
        roomBelow: Bool
    ) -> Placement {
        let trailing: Bool
        if cardWidth < barWidth + Space.two {
            trailing = true
        } else {
            switch corner {
            case .topTrailing, .bottomTrailing: trailing = true
            case .topLeading, .bottomLeading, nil: trailing = false
            }
        }
        let above: Bool
        switch corner {
        case .topLeading, .topTrailing:
            above = roomAbove
        case .bottomLeading, .bottomTrailing, nil:
            above = !roomBelow
        }
        switch (above, trailing) {
        case (false, false): return .belowLeading
        case (false, true): return .belowTrailing
        case (true, false): return .aboveLeading
        case (true, true): return .aboveTrailing
        }
    }
}
