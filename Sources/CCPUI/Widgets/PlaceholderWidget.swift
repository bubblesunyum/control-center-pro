// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// A widget with its real content not yet wired.
///
/// The shell is being built and reviewed before any engine is connected, so
/// these stand in: each carries the id, title, icon and size the real widget
/// will ship with, and draws a skeleton in place of its content. Replacing one
/// is a matter of writing `makeView()` on the real conformer — the layout that
/// placed it doesn't change, because it only ever knew the id.
@MainActor
protocol PlaceholderWidget: CCPWidget {}

extension PlaceholderWidget {
    func makeView() -> some View {
        WidgetCard(Self.descriptor) {
            ContentSkeleton(size: Self.descriptor.size)
        }
    }
}

/// Muted bars roughly where the real content will sit — enough to judge the
/// glass, the gutters and the type against, and unmistakably not real data.
///
/// Handed a sampler, the bars move with it: the one placeholder that actually
/// samples looks like it is doing something, and the panel shows at a glance
/// whether sampling stopped when it should have.
struct ContentSkeleton: View {
    let size: WidgetSize
    var sampler: PlaceholderSampler?

    private static let widths: [CGFloat] = [1, 0.72, 0.88, 0.6]

    /// A compact widget is one row of controls, so a skeleton that draws four
    /// of them makes every card the same height and the declared sizes a lie.
    private var widths: [CGFloat] {
        switch size {
        case .compact: Array(Self.widths.prefix(1))
        case .regular: Array(Self.widths.prefix(3))
        case .tall: Self.widths
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.one) {
            ForEach(widths.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.controlFill)
                    .frame(height: Space.one)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(x: width(at: index), anchor: .leading)
            }
        }
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.6), value: sampler?.tick)
    }

    /// A bar's resting width, nudged by the sample count. Derived rather than
    /// random so the same tick always draws the same skeleton — a screenshot
    /// of this card is worth comparing against the last one.
    private func width(at index: Int) -> CGFloat {
        let resting = widths[index]
        guard let sampler else { return resting }
        let phase = Double(sampler.tick + index)
        return resting * (0.88 + 0.12 * (sin(phase) + 1) / 2)
    }
}
