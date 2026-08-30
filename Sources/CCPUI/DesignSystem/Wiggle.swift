// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

public extension View {
    /// The iOS home-screen wiggle: a card that has come loose and can be moved.
    ///
    /// Each card gets its own period and its own head start, both drawn once
    /// when it first appears. Cards that wiggle in lockstep read as one sheet
    /// rocking rather than as a dozen loose tiles, which is the whole thing
    /// this is meant to say.
    func wiggling(_ isActive: Bool) -> some View {
        modifier(Wiggle(isActive: isActive))
    }
}

private struct Wiggle: ViewModifier {
    let isActive: Bool

    @State private var isRocked = false
    @State private var period = Double.random(in: 0.13...0.17)
    @State private var headStart = Double.random(in: 0...0.2)

    private static let amplitude = 0.7

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(isRocked ? Self.amplitude : -Self.amplitude))
            .animation(
                isActive
                    ? .easeInOut(duration: period).repeatForever(autoreverses: true)
                    : .easeOut(duration: period),
                value: isRocked
            )
            .task(id: isActive) {
                guard isActive else { return isRocked = false }
                // The head start is what desynchronises them: the animation
                // itself can't be given a phase, so the card is simply late to
                // start rocking.
                try? await Task.sleep(for: .seconds(headStart))
                isRocked = true
            }
    }
}
