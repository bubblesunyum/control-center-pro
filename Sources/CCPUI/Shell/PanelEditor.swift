// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import Observation
import SwiftUI

/// Edit mode: whether the panel is being rearranged, what is currently in the
/// air, and where letting go would put it.
///
/// The arrangement owns *what* the layout is; this owns the gesture in
/// progress. Keeping them apart is what lets a drag mutate the real layout on
/// every frame — the panel reorders live under the finger, and the thing being
/// dragged is drawn from here rather than from its lane.
///
/// What was picked up and where the finger is are separate properties on
/// purpose. The first changes twice a drag and the second changes every frame,
/// and the panel window resizes off the first: reading them together would put
/// a window resize inside each frame of a drag.
@MainActor
@Observable
final class PanelEditor {
    private(set) var isEditing = false
    private(set) var lifted: Lifted?
    private(set) var fingerAt: CGPoint = .zero
    private(set) var previewLanding: Landing?

    /// How many lanes this display can show. Set by the controller, which is
    /// the only thing that knows what screen the panel is on.
    var laneCapacity = Int.max

    /// Where every slot currently sits, in panel coordinates. Reported by the
    /// lanes themselves as they lay out, because their real frames are the only
    /// honest answer to what is under the finger.
    @ObservationIgnored var zones: [DropZone] = []

    /// The zones as they were when the lift started. While the finger is down
    /// the lanes animate under it; hit-testing against the live, moving frames
    /// each pixel makes the drop target thrash and kills the gesture when its
    /// view moves between lanes. Freezing the map at lift and only recomputing
    /// the pending landing is what keeps the drag coherent.
    @ObservationIgnored private var snapshotZones: [DropZone] = []

    var isDragging: Bool { lifted != nil }

    /// A card in the air: which one, how big, and whereabouts on it the user
    /// took hold.
    struct Lifted: Equatable {
        let id: WidgetID
        let size: CGSize
        let grab: CGSize

        static let scale: CGFloat = 1.04

        /// Visual center of the scaled card when the finger is at `point`.
        func visualCenter(at point: CGPoint) -> CGPoint {
            CGPoint(
                x: point.x - grab.width * Self.scale + size.width * Self.scale / 2,
                y: point.y - grab.height * Self.scale + size.height * Self.scale / 2
            )
        }

        /// Offset for the overlay that draws the scaled card at the finger.
        func offset(at point: CGPoint) -> CGSize {
            let delta = CGSize(width: size.width * (Self.scale - 1) / 2, height: size.height * (Self.scale - 1) / 2)
            return CGSize(
                width: point.x - grab.width * Self.scale + delta.width,
                height: point.y - grab.height * Self.scale + delta.height
            )
        }
    }

    /// One slot's claim on a piece of the panel.
    struct DropZone: Equatable {
        let id: WidgetID
        let lane: Int
        let frame: CGRect
    }

    /// Where a drop would put the card in the air.
    enum Landing: Equatable {
        case into(lane: Int, index: Int)
        case newLane(at: Int)
    }

    func startEditing() {
        isEditing = true
    }

    func stopEditing() {
        isEditing = false
        resetDragState()
    }

    private func resetDragState() {
        lifted = nil
        previewLanding = nil
        snapshotZones = []
    }

    func lift(_ id: WidgetID, at location: CGPoint) {
        guard let zone = zones.first(where: { $0.id == id }) else { return }
        fingerAt = location
        snapshotZones = zones
        let newLifted = Lifted(
            id: id,
            size: zone.frame.size,
            grab: CGSize(
                width: location.x - zone.frame.minX,
                height: location.y - zone.frame.minY
            )
        )
        lifted = newLifted
        // Keep the grid visually stable at lift: the gap starts where the
        // card was, so nothing collapses until the finger actually moves it.
        // Without this, `visibleSlots` filters the lifted card and the lane
        // shrinks by one card height the moment you pick it up.
        // Use the ghost's visual center, like `landing(using:)` does, so the
        // first drag tick doesn't thrash the gap one slot.
        let lane = zone.lane
        let settled = snapshotZones
            .filter { $0.lane == lane && $0.id != id }
            .sorted { $0.frame.minY < $1.frame.minY }
        let visualCenter = newLifted.visualCenter(at: location)
        let index = settled.filter { $0.frame.midY < visualCenter.y }.count
        previewLanding = .into(lane: lane, index: index)
    }

    /// Window grew/shrank while dragging (new-lane target appeared). The
    /// frozen snapshot is in the old panel coordinate space, but the finger
    /// and the live zones are now in the new one — shift the snapshot so
    /// hit-testing stays aligned with what the eye sees.
    func shiftSnapshot(dx: CGFloat) {
        guard !snapshotZones.isEmpty else { return }
        snapshotZones = snapshotZones.map {
            PanelEditor.DropZone(id: $0.id, lane: $0.lane, frame: $0.frame.offsetBy(dx: dx, dy: 0))
        }
        // Keep the gap's lane index stable — the preview was computed from
        // the old snapshot, but the gap is drawn from `previewLanding` alone,
        // which is lane/index based and doesn't need shifting.
    }

    func drag(to location: CGPoint) {
        fingerAt = location
    }

    func drag(to location: CGPoint, laneCount: Int) {
        fingerAt = location
        previewLanding = landing(using: snapshotZones, laneCount: laneCount)
    }

    func drop() { resetDragState() }

    /// A gesture that was cancelled (system interruption, second finger,
    /// view identity change) never calls `onEnded` — without this the card
    /// hangs in the air and the panel stops responding to clicks.
    func cancel() { resetDragState() }

    /// Whether the panel is holding a column open for the card in the air.
    /// Offered only while the ghost hovers the leading edge, not for the
    /// whole drag — inserting a full lane at lift shifts the entire grid
    /// right inside the panel and, even with the window growing left to
    /// compensate, the two animations desync and the grid visibly jumps the
    /// moment you pick a card up.
    func isOfferingNewLane(laneCount: Int) -> Bool {
        previewLanding == .newLane(at: 0) && canAddLane(to: laneCount)
    }

    /// Where the card in the air would land: the lane under the finger and the
    /// position within it the other cards leave room for, or a lane of its own.
    ///
    /// The index counts the cards it would sit *below*, and counts them with
    /// the dragged card already lifted out — which is the index
    /// `PanelLayout.moving(_:toLane:at:)` takes, and is why dragging a card
    /// down its own lane doesn't land it one short.
    func landing(laneCount: Int) -> Landing? {
        guard lifted != nil else { return nil }
        // While dragging, the live frames are animating under the finger;
        // hit-test against the frozen snapshot so the target doesn't thrash
        // each pixel. Before a lift there is no snapshot, so fall back to
        // live zones.
        let source = isDragging && !snapshotZones.isEmpty ? snapshotZones : zones
        return landing(using: source, laneCount: laneCount)
    }

    private func landing(using source: [DropZone], laneCount: Int) -> Landing? {
        guard let lifted else { return nil }

        // Where the card *looks* like it is, not where the fingertip is. The
        // finger holds the card at `grab` inside it, so a tip near the bottom
        // of a tall card is ~60pt below its center — using `fingerAt` directly
        // puts the gap one slot low.
        let center = lifted.visualCenter(at: fingerAt)

        if let lane = source.first(where: { $0.frame.minX <= center.x && center.x <= $0.frame.maxX })?.lane {
            let settled = source.filter { $0.lane == lane && $0.id != lifted.id }
            return .into(lane: lane, index: settled.filter { $0.frame.midY < center.y }.count)
        }

        // Left of every card is the column the panel would grow into.
        guard let leftmost = source.map(\.frame.minX).min(), center.x < leftmost else { return nil }
        return canAddLane(to: laneCount) ? .newLane(at: 0) : nil
    }

    func canAddLane(to laneCount: Int) -> Bool {
        laneCount < laneCapacity
    }
}

/// The panel's own coordinate space. Every frame edit mode reasons about — the
/// slots, the finger, the card in the air — is measured in this one, so that
/// none of the arithmetic depends on where a lane happens to start.
extension CoordinateSpaceProtocol where Self == NamedCoordinateSpace {
    static var panel: NamedCoordinateSpace { .named("ccp.panel") }
}

/// How the lanes tell the editor where their slots ended up.
struct DropZonePreference: PreferenceKey {
    static var defaultValue: [PanelEditor.DropZone] = []

    static func reduce(value: inout [PanelEditor.DropZone], nextValue: () -> [PanelEditor.DropZone]) {
        value += nextValue()
    }
}
