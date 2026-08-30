// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

/// Where the widgets sit: vertical lanes, each an ordered list of widget ids.
///
/// Plain data, and deliberately ignorant of the registry — it stores names, and
/// turning a name into a live widget is `WidgetRegistry.resolve(_:)`'s job.
/// That ignorance is what makes the file non-destructive: a layout naming a
/// widget this build has never heard of decodes intact and is written back
/// intact, so moving between builds with different widget sets costs nothing.
public struct PanelLayout: Codable, Hashable, Sendable {
    public typealias Lane = [WidgetID]

    public var lanes: [Lane]

    public init(_ lanes: [Lane]) {
        self.lanes = lanes
    }

    /// One lane, holding nothing. The floor `normalized()` keeps, and what an
    /// arrangement emptied of every widget collapses to.
    public static let empty = PanelLayout([[]])

    /// The layout with each widget placed at most once and its empty lanes
    /// closed up.
    ///
    /// Applied when a layout is loaded and after anything rearranges one —
    /// never inside `init(from:)`, which stays a faithful reading of the file.
    /// A lane emptied of its last widget would otherwise open the panel onto a
    /// blank column that looks like a bug, and removing the last widget
    /// altogether would leave a panel with no width at all.
    ///
    /// A widget is placed once because a panel holding two of the same card is
    /// a file that was hand-edited or half-written, not an arrangement anyone
    /// asked for — and the shell keys its lanes on the widget id, so the
    /// duplicate would render undefined. The first placement is the one kept.
    public func normalized() -> PanelLayout {
        var placed: Set<WidgetID> = []
        let occupied = lanes
            .map { $0.filter { placed.insert($0).inserted } }
            .filter { !$0.isEmpty }
        return occupied.isEmpty ? .empty : PanelLayout(occupied)
    }
}
