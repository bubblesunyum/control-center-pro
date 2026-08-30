// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// A widget's card: a titled header over its content, inset from the glass.
///
/// This is what a widget writes when its content isn't a list of full-width
/// rows. It exists so a dozen unrelated widgets agree on where their title sits
/// without any of them saying so.
public struct WidgetCard<Content: View>: View {
    private let descriptor: WidgetDescriptor
    private let content: Content

    public init(_ descriptor: WidgetDescriptor, @ViewBuilder content: () -> Content) {
        self.descriptor = descriptor
        self.content = content()
    }

    public var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Space.one) {
                header
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Space.oneHalf)
        }
    }

    private var header: some View {
        Label(descriptor.title, systemImage: descriptor.symbolName)
            .font(.headline)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.primary)
            .lineLimit(1)
    }
}
