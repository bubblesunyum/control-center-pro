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
    static let white24 = Color.white.opacity(0.24)
    static let black24 = Color.black.opacity(0.24)
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
    /// Fill for a pressable surface inside a card, at rest.
    static let controlFill = Ink.white08
    static let cardShadow = Ink.black24

    /// What an active toggle reads as. Named so widgets ask for the meaning
    /// rather than for the system accent, which is where a different answer
    /// would go if one is ever needed.
    static let widgetAccent = Color.accentColor
    static let labelMuted = Color.secondary
}
