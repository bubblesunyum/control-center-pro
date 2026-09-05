// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// A widget's card: a ``WidgetHeader`` over its content, inset from the glass.
///
/// This is what a widget writes when its content isn't a list of full-width
/// rows. It exists so a dozen unrelated widgets agree on where their title sits
/// without any of them saying so — a widget that needs a count or a button up
/// there passes them here rather than hand-rolling a header beside everyone
/// else's.
public struct WidgetCard<Content: View, Accessory: View>: View {
    private let descriptor: WidgetDescriptor
    private let count: Int?
    private let isAccessoryExpanded: Bool
    private let accessory: Accessory
    private let content: Content

    public init(
        _ descriptor: WidgetDescriptor,
        count: Int? = nil,
        isAccessoryExpanded: Bool = false,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.descriptor = descriptor
        self.count = count
        self.isAccessoryExpanded = isAccessoryExpanded
        self.accessory = accessory()
        self.content = content()
    }

    public var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Space.one) {
                WidgetHeader(descriptor, count: count, isAccessoryExpanded: isAccessoryExpanded) { accessory }
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Space.oneHalf)
        }
    }
}

public extension WidgetCard where Accessory == EmptyView {
    init(
        _ descriptor: WidgetDescriptor,
        count: Int? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(descriptor, count: count, accessory: { EmptyView() }, content: content)
    }
}
