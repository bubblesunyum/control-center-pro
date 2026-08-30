// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Observation

/// The arrangement as it currently stands: live widgets in lanes, and the
/// stored layout that describes them.
///
/// `PanelLayout` is the names on disk and `LaneSlot` is what a lane draws; this
/// is the one object that holds both and keeps them saying the same thing. It
/// exists because two separate things need exactly that pairing — starting and
/// stopping the widgets that are placed, and rearranging them — and neither is
/// the panel window's business or the file's.
@MainActor
@Observable
public final class PanelArrangement {
    public private(set) var layout: PanelLayout
    public private(set) var lanes: [[LaneSlot]]

    @ObservationIgnored private let registry: WidgetRegistry
    @ObservationIgnored private let autosave: LayoutAutosave?

    /// One live widget per placed id, kept across rearrangements: a widget
    /// dragged to another lane is the same object when it lands, so whatever
    /// it was showing survives the trip.
    @ObservationIgnored private var instances: [WidgetID: WidgetInstance] = [:]

    /// Whether the widgets are currently sampling. Held because activation is
    /// idempotent: the panel can be shown twice without the second one
    /// stacking a second timer inside every widget.
    @ObservationIgnored private var isActive = false

    public init(
        _ layout: PanelLayout,
        registry: WidgetRegistry,
        autosave: LayoutAutosave? = nil
    ) {
        self.registry = registry
        self.autosave = autosave
        self.layout = layout.normalized()
        lanes = []
        lanes = resolved()
    }

    /// Every live widget on the panel, in no particular order — the slots that
    /// only stand in for an absent one have nothing to start.
    private var widgets: [WidgetInstance] {
        lanes.flatMap { $0 }.compactMap(\.instance)
    }

    // MARK: - Rearranging

    /// Put `id` down in `lane` at `index`. A lane one past the last makes a
    /// new one.
    public func move(_ id: WidgetID, toLane lane: Int, at index: Int) {
        apply(layout.moving(id, toLane: lane, at: index))
    }

    /// Put `id` in a lane of its own, opened at `lane`.
    public func move(_ id: WidgetID, toNewLaneAt lane: Int) {
        apply(layout.moving(id, toNewLaneAt: lane))
    }

    /// Take `id` off the panel. Its widget is stopped on the way out — a
    /// removed widget that kept sampling would be the leak the lifecycle
    /// exists to prevent, arriving by another door.
    public func remove(_ id: WidgetID) {
        apply(layout.removing(id))
    }

    private func apply(_ rearranged: PanelLayout) {
        guard rearranged != layout else { return }
        layout = rearranged
        lanes = resolved()
        autosave?.schedule(rearranged)
    }

    /// Write anything the autosave is still holding. The panel is closing or
    /// the app is quitting, and a debounce outrun by either loses the edit.
    public func flush() {
        autosave?.flush()
    }

    /// The layout as slots, reusing the widgets already made and retiring the
    /// ones no longer placed.
    private func resolved() -> [[LaneSlot]] {
        let placed = Set(layout.lanes.joined())
        for (id, instance) in instances where !placed.contains(id) {
            if isActive { instance.deactivate() }
            instances[id] = nil
        }
        return layout.lanes.map { $0.map(resolvedSlot(for:)) }
    }

    /// The slot a widget currently occupies. Edit mode asks so it can draw the
    /// card it has in the air, which is no longer being drawn by its lane.
    public func slot(for id: WidgetID) -> LaneSlot? {
        lanes.joined().first { $0.id == id }
    }

    private func resolvedSlot(for id: WidgetID) -> LaneSlot {
        if let placed = instances[id] { return .widget(placed) }
        guard let made = registry.makeInstance(of: id) else { return .unavailable(id) }
        instances[id] = made
        // A widget that arrives while the panel is open starts now; one placed
        // before it opened is started by `activate()` along with the rest.
        if isActive { made.activate() }
        return .widget(made)
    }

    /// Start sampling. The panel is on screen.
    public func activate() {
        guard !isActive else { return }
        isActive = true
        widgets.forEach { $0.activate() }
    }

    /// Stop sampling. With the panel shut the app's job is to cost nothing,
    /// and a widget still holding a timer is the only way it could cost
    /// something.
    public func deactivate() {
        guard isActive else { return }
        isActive = false
        widgets.forEach { $0.deactivate() }
    }
}
