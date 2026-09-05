// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

/// Where the widgets sit: vertical lanes, each an ordered list of placements.
///
/// Plain data, and deliberately ignorant of the registry — it stores names, and
/// turning a name into a live widget is `WidgetRegistry.resolve(_:)`'s job.
/// That ignorance is what makes the file non-destructive: a layout naming a
/// widget this build has never heard of decodes intact and is written back
/// intact, so moving between builds with different widget sets costs nothing.
public struct PanelLayout: Codable, Hashable, Sendable {
    public typealias Lane = [Placement]

    public var lanes: [Lane]

    public init(_ lanes: [Lane]) {
        self.lanes = lanes
    }

    /// A layout written with bare ids — every placement at its base size. What
    /// the default layout, the gallery, and a file from before resizes existed
    /// all look like.
    public init(_ ids: [[WidgetID]]) {
        self.lanes = ids.map { $0.map { Placement(id: $0) } }
    }

    /// The same lanes as bare ids. Order and membership without the sizes —
    /// what most comparisons want.
    public var ids: [[WidgetID]] {
        lanes.map { $0.map(\.id) }
    }

    /// One lane, holding nothing. The floor `normalized()` keeps, and what an
    /// arrangement emptied of every widget collapses to.
    public static let empty = PanelLayout([[]] as [Lane])

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
    /// duplicate would render undefined. The first placement is the one kept,
    /// span and all.
    public func normalized() -> PanelLayout {
        var placed: Set<WidgetID> = []
        let occupied = lanes
            .map { $0.filter { placed.insert($0.id).inserted } }
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
    ///
    /// The placement moves whole: a resized widget lands at its size, because
    /// the span belongs to the widget rather than the slot it left.
    public func moving(_ id: WidgetID, toLane lane: Int, at index: Int) -> PanelLayout {
        guard let from = position(of: id), lane >= 0, lane <= lanes.count else { return self }

        var lifted = lanes
        let placement = lifted[from.lane].remove(at: from.index)
        if lane == lifted.count { lifted.append([]) }

        // Clamping rather than rejecting: the index comes from a finger, and
        // the end of the lane is what "below the last card" means.
        let destination = min(max(index, 0), lifted[lane].count)
        lifted[lane].insert(placement, at: destination)

        return PanelLayout(lifted).normalized()
    }

    /// The layout with `id` alone in a lane of its own, inserted at `lane`.
    ///
    /// Any gap takes one: the leading edge, between two lanes, or the
    /// trailing edge. A leading column keeps every card where it is on screen
    /// (the panel grows left and the lanes shift right inside it by the same
    /// amount); a middle or trailing one moves the lanes left of it while it
    /// previews — the price of opening where the drop will land.
    public func moving(_ id: WidgetID, toNewLaneAt lane: Int) -> PanelLayout {
        guard lane >= 0, lane <= lanes.count,
              let placement = lanes.joined().first(where: { $0.id == id }) else { return self }

        var opened = lanes.map { $0.filter { $0.id != id } }
        opened.insert([placement], at: lane)
        return PanelLayout(opened).normalized()
    }

    /// The layout with `id` added to whichever lane is carrying the least.
    ///
    /// The gallery says *what* to place, not where — there is no gesture in
    /// "add this one" to read a position out of, and the shortest lane is the
    /// one whose shape the panel changes least by growing. Already placed and
    /// nothing happens: a widget is on the panel once.
    public func adding(_ id: WidgetID) -> PanelLayout {
        guard position(of: id) == nil else { return self }

        var grown = lanes
        let shortest = grown.indices.min { grown[$0].count < grown[$1].count } ?? 0
        guard grown.indices.contains(shortest) else { return PanelLayout([[id]]) }
        grown[shortest].append(Placement(id: id))
        return PanelLayout(grown).normalized()
    }

    /// The layout without `id`. Removing the last widget leaves ``empty``
    /// rather than a panel with no width.
    public func removing(_ id: WidgetID) -> PanelLayout {
        PanelLayout(lanes.map { $0.filter { $0.id != id } }).normalized()
    }

    /// The layout with `id` resized to `span`. Naming a widget this layout
    /// doesn't place changes nothing — a resize grip only exists on a card
    /// that is already on the panel.
    public func resizing(_ id: WidgetID, to span: WidgetSpan) -> PanelLayout {
        guard position(of: id) != nil else { return self }
        return PanelLayout(lanes.map { $0.map { $0.id == id ? Placement(id: id, span: span) : $0 } })
    }

    /// Where a widget currently sits, or `nil` if this layout doesn't place it.
    public func position(of id: WidgetID) -> (lane: Int, index: Int)? {
        for (lane, widgets) in lanes.enumerated() {
            if let index = widgets.firstIndex(where: { $0.id == id }) { return (lane, index) }
        }
        return nil
    }
}
