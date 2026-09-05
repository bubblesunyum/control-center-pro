// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

/// The only place in the app a colour literal appears.
///
/// It is this short because the panel floats over an unknown wallpaper in
/// either appearance, and the system colours already solve that. What's left is
/// the glass vocabulary itself: white at a few alphas, which is what a hairline
/// and a highlight are made of.
private enum Ink {
    static let white08 = Color.white.opacity(0.08)
    static let white12 = Color.white.opacity(0.12)
    static let white14 = Color.white.opacity(0.14)
    static let white18 = Color.white.opacity(0.18)
    static let white24 = Color.white.opacity(0.24)
    static let black12 = Color.black.opacity(0.12)
    static let black24 = Color.black.opacity(0.24)
    static let black32 = Color.black.opacity(0.32)
}

public extension Color {
    /// A card is a *lightening* of the blurred wallpaper behind it, never a
    /// fill laid over it. A material here reads as a dark box floating on the
    /// desktop; white at a low alpha keeps the wallpaper's colour coming
    /// through, which is what makes the panel look like glass rather than like
    /// a window with a blurred picture inside it.
    static let cardFill = Ink.white12

    /// The hairline that separates a card from the blur behind it.
    static let cardStroke = Ink.white14
    /// The same hairline where a card is raised — a drag in progress.
    static let cardStrokeStrong = Ink.white24
    /// Hairline for an active toggle tile — subtle white to lift the accent fill.
    static let controlStrokeActive = Ink.white18
    /// Fill for a pressable surface inside a card, at rest.
    static let controlFill = Ink.white08
    static let cardShadow = Ink.black24

    /// The note surface sits two lightening fills above its card; without a
    /// scrim it reads as glare rather than as a surface set into the card. A
    /// black scrim darkens in either appearance, where leaning on the system
    /// background would darken in one and lighten in the other.
    static let noteScrim = Ink.black12
    /// The note well, set into the card. A heavy scrim with none of the
    /// card's lightening, so it reads as a hollow next to the glass around
    /// it rather than as another tile of it. A black scrim darkens in either
    /// appearance, where leaning on the system background would darken in one
    /// and lighten in the other.
    static let noteInset = Ink.black32

    /// What an active toggle reads as. Named so widgets ask for the meaning
    /// rather than for the system accent, which is where a different answer
    /// would go if one is ever needed.
    static let widgetAccent = Color.accentColor
    static let labelMuted = Color.secondary
    /// Baseline drawn behind a sparkline so its zero is readable.
    static let sparklineBaseline = Color.secondary.opacity(0.28)
    /// Faint fill under the secondary network line.
    static let sparklineSecondaryFill = Color.green.opacity(0.08)

    /// What a selected or engaged control reads as — a chosen pad's tab, a
    /// formatting mark that is on.
    static let selectedFill = Color.accentColor.opacity(0.14)

    /// Pinned clipboard row — faint accent so a pinned entry reads as kept.
    static let pinnedFill = Color.accentColor.opacity(0.09)
    static let pinnedStroke = Color.accentColor.opacity(0.22)

    /// Hover fill for a row in a custom menu popover, e.g. the Files overflow.
    static let menuRowHover = Color.primary.opacity(0.1)

    /// Dashed placeholder shown where a dragged card would land.
    static let dropGapStroke = Color.accentColor.opacity(0.55)
    static let dropGapFill = Color.accentColor.opacity(0.08)
    /// Dashed new-lane column, highlighted when the finger is over it.
    static let newLaneStrokeTargeted = Color.accentColor.opacity(0.65)
    static let newLaneFillTargeted = Color.accentColor.opacity(0.10)
}
