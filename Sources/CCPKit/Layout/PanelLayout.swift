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

    // MARK: - Rearranging
    //
    // Every verb here returns a normalized layout, because every one of them
    // can empty a lane. They take a widget by id rather than by where it
    // currently is: edit mode knows what is under the finger, and looking up
    // where that is happens once, here, instead of at each call site.

    /// The layout with `id` lifted out of wherever it sits and put down in
    /// `lane` at `index`.
    ///
    /// A `lane` one past the end appends a new one, which is how a drag into
    /// the trailing slot makes a column. Out of range in any other direction,
    /// or naming a widget this layout doesn't place, and nothing moves — a drag
    /// that ended somewhere meaningless should leave the panel as it was.
    public func moving(_ id: WidgetID, toLane lane: Int, at index: Int) -> PanelLayout {
        guard let from = position(of: id), lane >= 0, lane <= lanes.count else { return self }

        var lifted = lanes
        lifted[from.lane].remove(at: from.index)
        if lane == lifted.count { lifted.append([]) }

        // Clamping rather than rejecting: the index comes from a finger, and
        // the end of the lane is what "below the last card" means.
        let destination = min(max(index, 0), lifted[lane].count)
        lifted[lane].insert(id, at: destination)

        return PanelLayout(lifted).normalized()
    }

    /// The layout with `id` alone in a lane of its own, inserted at `lane`.
    ///
    /// The panel is anchored to the right of the screen and grows leftward, so
    /// the lane a drag creates is the new leftmost one — which is the only
    /// place a column can appear without shoving every card already on screen
    /// sideways while the user is still holding one.
    public func moving(_ id: WidgetID, toNewLaneAt lane: Int) -> PanelLayout {
        guard position(of: id) != nil, lane >= 0, lane <= lanes.count else { return self }

        var opened = lanes.map { $0.filter { $0 != id } }
        opened.insert([id], at: lane)
        return PanelLayout(opened).normalized()
    }

    /// The layout without `id`. Removing the last widget leaves ``empty``
    /// rather than a panel with no width.
    public func removing(_ id: WidgetID) -> PanelLayout {
        PanelLayout(lanes.map { $0.filter { $0 != id } }).normalized()
    }

    /// Where a widget currently sits, or `nil` if this layout doesn't place it.
    public func position(of id: WidgetID) -> (lane: Int, index: Int)? {
        for (lane, widgets) in lanes.enumerated() {
            if let index = widgets.firstIndex(of: id) { return (lane, index) }
        }
        return nil
    }
}
