// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

/// What a widget is, independent of where it currently sits.
///
/// Everything here is intrinsic to the widget kind — its identity, how it names
/// and draws itself in a gallery, how much room it asks for, what the system
/// must let it see. Which lane it happens to occupy is the layout's business and
/// deliberately absent.
public struct WidgetDescriptor: Identifiable, Hashable, Sendable {
    public let id: WidgetID
    public let title: String
    /// SF Symbol name, used wherever the widget represents itself as an icon.
    public let symbolName: String
    public let size: WidgetSize
    public let permissions: Set<WidgetPermission>

    public init(
        id: WidgetID,
        title: String,
        symbolName: String,
        size: WidgetSize = .regular,
        permissions: Set<WidgetPermission> = []
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.size = size
        self.permissions = permissions
    }
}

/// How much room a widget asks for.
///
/// Named rather than measured: the widget knows it needs a graph's worth of
/// height, and what that is in points is the design system's call. Every size
/// but `.screen` takes the lane's own width — a lane is as wide as the widest
/// thing in it.
public enum WidgetSize: String, Codable, Sendable, CaseIterable {
    /// A single row — a toggle, a readout.
    case compact
    /// A few rows of controls.
    case regular
    /// A graph or a scrolling list.
    case tall
    /// A whole app screen carried in the panel, with its own navigation and
    /// chrome — wider than a lane of cards, and tall enough to work in rather
    /// than glance at.
    case screen
}

/// A system permission a widget cannot work without.
///
/// A widget missing one degrades to an inline grant prompt; it never keeps the
/// panel from opening, which is why this is a property of the widget rather
/// than a gate in the shell.
public enum WidgetPermission: String, Codable, Sendable, CaseIterable {
    /// CoreAudio process taps, for the per-app mixer.
    case audioCapture
    /// Accessibility, for the window features that land after v1.
    case accessibility
}
