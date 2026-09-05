// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI

/// Thin capacity bar for a fractional readout.
///
/// The fill is the caller's tint, or the accent color when none is given. When
/// `warningTint` is set, the leading edge gradients into it at the trailing
/// tip — how System Stats shows memory pressure creeping in.
public struct UsageBar: View {
    public let fraction: Double
    public var tint: Color? = nil
    public var warningTint: Color? = nil

    public init(fraction: Double, tint: Color? = nil, warningTint: Color? = nil) {
        self.fraction = fraction
        self.tint = tint
        self.warningTint = warningTint
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(barFill())
                    .frame(width: max(3, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }

    private func barFill() -> AnyShapeStyle {
        let base = tint ?? .accentColor
        guard let warning = warningTint else {
            return AnyShapeStyle(base)
        }
        return AnyShapeStyle(
            LinearGradient(
                stops: [
                    .init(color: base, location: 0.0),
                    .init(color: base, location: 0.72),
                    .init(color: warning, location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
}
