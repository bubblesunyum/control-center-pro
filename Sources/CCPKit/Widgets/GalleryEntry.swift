// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

/// One line in the gallery: a widget this build offers, and whether the panel
/// already has it.
///
/// The descriptor alone can't say — it describes a *kind* of widget and knows
/// nothing about where any of them sit, which is exactly the separation that
/// keeps a widget from having to know about lanes.
public struct GalleryEntry: Identifiable, Hashable, Sendable {
    public let descriptor: WidgetDescriptor
    public let isPlaced: Bool

    public var id: WidgetID { descriptor.id }

    public init(descriptor: WidgetDescriptor, isPlaced: Bool) {
        self.descriptor = descriptor
        self.isPlaced = isPlaced
    }
}
