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

    /// How many lanes this display can show. Set by the controller, which is
    /// the only thing that knows what screen the panel is on.
    var laneCapacity = Int.max

    /// Where every slot currently sits, in panel coordinates. Reported by the
    /// lanes themselves as they lay out, because their real frames are the only
    /// honest answer to what is under the finger.
    @ObservationIgnored var zones: [DropZone] = []

    /// A card in the air: which one, how big, and whereabouts on it the user
    /// took hold.
    struct Lifted: Equatable {
        let id: WidgetID
        let size: CGSize
        let grab: CGSize
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
        lifted = nil
    }

    func lift(_ id: WidgetID, at location: CGPoint) {
        guard let zone = zones.first(where: { $0.id == id }) else { return }
        fingerAt = location
        lifted = Lifted(
            id: id,
            size: zone.frame.size,
            grab: CGSize(
                width: location.x - zone.frame.minX,
                height: location.y - zone.frame.minY
            )
        )
    }

    func drag(to location: CGPoint) {
        fingerAt = location
    }

    func drop() {
        lifted = nil
    }

    /// Whether the panel is holding a column open for the card in the air. It
    /// is offered for the whole drag rather than only when the finger is over
    /// it, because an offer nobody can see is not one.
    func isOfferingNewLane(laneCount: Int) -> Bool {
        lifted != nil && canAddLane(to: laneCount)
    }

    /// Where the card in the air would land: the lane under the finger and the
    /// position within it the other cards leave room for, or a lane of its own.
    ///
    /// The index counts the cards it would sit *below*, and counts them with
    /// the dragged card already lifted out — which is the index
    /// `PanelLayout.moving(_:toLane:at:)` takes, and is why dragging a card
    /// down its own lane doesn't land it one short.
    func landing(laneCount: Int) -> Landing? {
        guard let lifted else { return nil }

        if let lane = zones.first(where: { $0.frame.minX <= fingerAt.x && fingerAt.x <= $0.frame.maxX })?.lane {
            let settled = zones.filter { $0.lane == lane && $0.id != lifted.id }
            return .into(lane: lane, index: settled.filter { $0.frame.midY < fingerAt.y }.count)
        }

        // Left of every card is the column the panel would grow into.
        guard let leftmost = zones.map(\.frame.minX).min(), fingerAt.x < leftmost else { return nil }
        return isOfferingNewLane(laneCount: laneCount) ? .newLane(at: 0) : nil
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
