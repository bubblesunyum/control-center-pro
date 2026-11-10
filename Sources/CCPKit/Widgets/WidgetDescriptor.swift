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
    /// Whether the widget offers a minimized form behind a header caret.
    /// Intrinsic to the widget kind — a compact summary it knows how to draw —
    /// so it lives here; which widgets are currently minimized lives on the
    /// layout's placements.
    public let isMinimizable: Bool

    public init(
        id: WidgetID,
        title: String,
        symbolName: String,
        size: WidgetSize = .regular,
        permissions: Set<WidgetPermission> = [],
        isMinimizable: Bool = false
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.size = size
        self.permissions = permissions
        self.isMinimizable = isMinimizable
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

/// How resizes were stored before they were free: multiples of the widget's
/// base size, 1x to 3x per axis. Nothing writes one any more; a layout file
/// from then still carries them, and the shell draws such a card at the
/// points its span used to mean until it is resized again.
public struct WidgetSpan: Codable, Hashable, Sendable {
    /// The largest multiple a resize can reach, per axis.
    public static let maximum = 3

    /// No resize: the widget at its base size.
    public static let unit = WidgetSpan(width: 1, height: 1)

    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = min(max(width, 1), Self.maximum)
        self.height = min(max(height, 1), Self.maximum)
    }
}

/// A widget's size in points: whatever rect the user dragged it to, in any
/// axis, with no step and no per-widget floor or ceiling. Named for the
/// on-disk key it has always had.
public struct CustomWidgetSize: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
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
