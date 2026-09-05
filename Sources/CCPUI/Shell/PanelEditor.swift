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
public final class PanelEditor {
    public private(set) var isEditing = false
    public private(set) var lifted: Lifted?
    public private(set) var fingerAt: CGPoint = .zero
    public private(set) var previewLanding: Landing?
    public var isShowingGallery = false

    /// How wide the display showing the panel is. Set by the controller, which
    /// is the only thing that knows what screen the panel is on. Whether one
    /// more lane fits depends on the lanes already placed as well as this, so
    /// it is the width that is stored rather than a count.
    public var displayWidth = CGFloat.greatestFiniteMagnitude

    /// Where every slot currently sits, in panel coordinates. Reported by the
    /// lanes themselves as they lay out, because their real frames are the only
    /// honest answer to what is under the finger.
    @ObservationIgnored public var zones: [DropZone] = []

    /// The zones as they were when the lift started. While the finger is down
    /// the lanes animate under it; hit-testing against the live, moving frames
    /// each pixel makes the drop target thrash and kills the gesture when its
    /// view moves between lanes. Freezing the map at lift and only recomputing
    /// the pending landing is what keeps the drag coherent.
    @ObservationIgnored private var snapshotZones: [DropZone] = []

    public var isDragging: Bool { lifted != nil }

    /// A card in the air: which one, how big, and whereabouts on it the user
    /// took hold.
    public struct Lifted: Equatable {
        let id: WidgetID
        let size: CGSize
        let grab: CGSize

        public static let scale: CGFloat = 1.04

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
    public struct DropZone: Equatable {
        public let id: WidgetID
        public let lane: Int
        public let frame: CGRect

        public init(id: WidgetID, lane: Int, frame: CGRect) {
            self.id = id
            self.lane = lane
            self.frame = frame
        }
    }

    /// Where a drop would put the card in the air.
    public enum Landing: Equatable {
        case into(lane: Int, index: Int)
        case newLane(at: Int)
    }

    public func startEditing() {
        isEditing = true
    }

    public func stopEditing() {
        isEditing = false
        isShowingGallery = false
        endResize()
        resetDragState()
    }

    /// Exit edit mode but keep the gallery open — used by the menu bar
    /// checkmark so adding widgets can continue without re-opening the gallery.
    public func finishEditingPreservingGallery() {
        isEditing = false
        endResize()
        resetDragState()
    }

    private func resetDragState() {
        lifted = nil
        previewLanding = nil
        snapshotZones = []
    }

    public func lift(_ id: WidgetID, at location: CGPoint) {
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
        // first drag tick doesn't thrash the gap one slot. The lane keeps
        // the lifted card's frame for banding — lifting one half of a shared
        // row must not collapse the row before the finger moves, or the drop
        // without moving lands in the mate's seat and a no-op swaps the pair.
        let laneCards = snapshotZones
            .filter { $0.lane == zone.lane }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        previewLanding = .into(
            lane: zone.lane,
            index: indexBelow(newLifted.visualCenter(at: location), in: laneCards, skipping: id)
        )
    }

    /// Window grew/shrank while dragging (new-lane target appeared). The
    /// frozen snapshot is in the old panel coordinate space, but the finger
    /// and the live zones are now in the new one — shift the snapshot so
    /// hit-testing stays aligned with what the eye sees.
    public func shiftSnapshot(dx: CGFloat) {
        guard !snapshotZones.isEmpty else { return }
        snapshotZones = snapshotZones.map {
            PanelEditor.DropZone(id: $0.id, lane: $0.lane, frame: $0.frame.offsetBy(dx: dx, dy: 0))
        }
        // Keep the gap's lane index stable — the preview was computed from
        // the old snapshot, but the gap is drawn from `previewLanding` alone,
        // which is lane/index based and doesn't need shifting.
    }

    public func drag(to location: CGPoint) {
        fingerAt = location
    }

    public func drag(to location: CGPoint, laneWidths: [CGFloat]) {
        fingerAt = location
        previewLanding = landing(using: snapshotZones, laneWidths: laneWidths)
    }

    public func drop() { resetDragState() }

    /// A gesture that was cancelled (system interruption, second finger,
    /// view identity change) never calls `onEnded` — without this the card
    /// hangs in the air and the panel stops responding to clicks.
    public func cancel() { resetDragState() }

    // MARK: - Resizing
    //
    // A resize previews in here and commits to the layout once, on release —
    // the same one-mutation shape as a drag. Mutating the layout per pixel
    // would re-resolve the arrangement and re-schedule the autosave every
    // frame; a preview is just a span the lane draws instead of the stored
    // one until the finger comes up.

    /// The card under the grip and the span it would land at, or `nil` when
    /// no grip is being dragged.
    public private(set) var resizePreview: ResizePreview?

    public struct ResizePreview: Equatable {
        let id: WidgetID
        var span: WidgetSpan
        /// The span the drag started from. The preview never touches the
        /// layout mid-gesture, but the gesture may outlive the view that
        /// started it — so the origin travels with the preview rather than
        /// being re-read off a slot.
        let start: WidgetSpan
        /// The step the drag counts in: the widget's base size, so steps stay
        /// the same width wherever the drag starts.
        let baseSize: CGSize
    }

    public func beginResize(_ id: WidgetID, from start: WidgetSpan, baseSize: CGSize) {
        // One grip at a time: a second finger never preempts the drag already
        // in flight, or the two releases wipe each other's preview out.
        guard resizePreview == nil else { return }
        resizePreview = ResizePreview(id: id, span: start, start: start, baseSize: baseSize)
    }

    /// The drag's translation, counted in whole steps from the span it
    /// started at: one lane-unit right is one width step, one base-height
    /// down is one height step. The span clamps to 1x–3x on the way in, so a
    /// wild drag parks at the end rather than somewhere meaningless.
    public func updateResize(translation: CGSize) {
        guard let preview = resizePreview else { return }
        let next = WidgetSpan(
            width: preview.start.width + Int((translation.width / preview.baseSize.width).rounded()),
            height: preview.start.height + Int((translation.height / preview.baseSize.height).rounded())
        )
        // Assigning the same span still notifies observers, and the window
        // tracker re-fits on every one — so only a changed step lands.
        guard next != preview.span else { return }
        resizePreview?.span = next
    }

    public func endResize() { resizePreview = nil }

    /// The slot as drawn while a resize is in flight: the card under the grip
    /// wears its preview span, everything else its stored one.
    public func previewing(_ slot: LaneSlot) -> LaneSlot {
        guard let preview = resizePreview, preview.id == slot.id else { return slot }
        return slot.resized(to: preview.span)
    }

    /// Whether widening `lane` to `width` still fits the display — the commit
    /// guard for a width grip, and the resize half of `fits(widths:)`.
    public func canResizeLane(_ lane: Int, to width: CGFloat, laneWidths: [CGFloat]) -> Bool {
        guard laneWidths.indices.contains(lane) else { return false }
        var widths = laneWidths
        widths[lane] = width
        return Layout.fits(widths: widths, inWidth: displayWidth)
    }

    /// Whether the panel is holding a column open for the card in the air.
    /// Offered only while the ghost hovers the leading edge, not for the
    /// whole drag — inserting a full lane at lift shifts the entire grid
    /// right inside the panel and, even with the window growing left to
    /// compensate, the two animations desync and the grid visibly jumps the
    /// moment you pick a card up.
    public func isOfferingNewLane(beside laneWidths: [CGFloat]) -> Bool {
        previewLanding == .newLane(at: 0) && canAddLane(beside: laneWidths)
    }

    /// Where the card in the air would land: the lane under the finger and the
    /// position within it the other cards leave room for, or a lane of its own.
    ///
    /// The index counts the cards it would sit *below*, and counts them with
    /// the dragged card already lifted out — which is the index
    /// `PanelLayout.moving(_:toLane:at:)` takes, and is why dragging a card
    /// down its own lane doesn't land it one short.
    public func landing(laneWidths: [CGFloat]) -> Landing? {
        guard lifted != nil else { return nil }
        // While dragging, the live frames are animating under the finger;
        // hit-test against the frozen snapshot so the target doesn't thrash
        // each pixel. Before a lift there is no snapshot, so fall back to
        // live zones.
        let source = isDragging && !snapshotZones.isEmpty ? snapshotZones : zones
        return landing(using: source, laneWidths: laneWidths)
    }

    private func landing(using source: [DropZone], laneWidths: [CGFloat]) -> Landing? {
        guard let lifted else { return nil }

        // Where the card *looks* like it is, not where the fingertip is. The
        // finger holds the card at `grab` inside it, so a tip near the bottom
        // of a tall card is ~60pt below its center — using `fingerAt` directly
        // puts the gap one slot low.
        let center = lifted.visualCenter(at: fingerAt)

        if let lane = source.first(where: { $0.frame.minX <= center.x && center.x <= $0.frame.maxX })?.lane {
            let cards = source.filter { $0.lane == lane }
                .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            return .into(lane: lane, index: indexBelow(center, in: cards, skipping: lifted.id))
        }

        // Left of every card is the column the panel would grow into.
        guard let leftmost = source.map(\.frame.minX).min(), center.x < leftmost else { return nil }
        return canAddLane(beside: laneWidths) ? .newLane(at: 0) : nil
    }

    /// The insertion index for `center` among the lane's cards, counted in
    /// layout order without the card in the air.
    ///
    /// Cards whose frames overlap vertically are one band — a row sharing the
    /// lane — and the finger's row decides by x: what is left of it comes
    /// first, and a band wholly above counts whole. The card in the air keeps
    /// its frame for banding but never counts: lifting one half of a shared
    /// row must not collapse the row, or dropping it without moving lands in
    /// its mate's seat. A band of one settled card is exactly the old midY
    /// rule, so single-column lanes land where they always have.
    private func indexBelow(_ center: CGPoint, in cards: [DropZone], skipping skipped: WidgetID) -> Int {
        var index = 0
        var i = cards.startIndex
        while i < cards.endIndex {
            var bandMaxY = cards[i].frame.maxY
            var j = cards.index(after: i)
            while j < cards.endIndex, cards[j].frame.minY < bandMaxY {
                bandMaxY = max(bandMaxY, cards[j].frame.maxY)
                j = cards.index(after: j)
            }
            let band = cards[i..<j]
            let others = band.filter { $0.id != skipped }
            if bandMaxY <= center.y {
                index += others.count
            } else if others.isEmpty {
                return index
            } else if band.count == 1 {
                if others.first!.frame.midY < center.y { index += 1 } else { return index }
            } else if band.first!.frame.minY > center.y {
                return index
            } else {
                return index + others.filter { $0.frame.midX < center.x }.count
            }
            i = j
        }
        return index
    }

    public func canAddLane(beside laneWidths: [CGFloat]) -> Bool {
        Layout.fitsAnotherLane(beside: laneWidths, inWidth: displayWidth)
    }
}

/// The panel's own coordinate space. Every frame edit mode reasons about — the
/// slots, the finger, the card in the air — is measured in this one, so that
/// none of the arithmetic depends on where a lane happens to start.
extension CoordinateSpaceProtocol where Self == NamedCoordinateSpace {
    static var panel: NamedCoordinateSpace { .named("ccp.panel") }
}

private struct PanelEditorKey: EnvironmentKey {
    static let defaultValue: PanelEditor? = nil
}

extension EnvironmentValues {
    var panelEditor: PanelEditor? {
        get { self[PanelEditorKey.self] }
        set { self[PanelEditorKey.self] = newValue }
    }
}

private struct PanelArrangementKey: EnvironmentKey {
    static let defaultValue: PanelArrangement? = nil
}

extension EnvironmentValues {
    var panelArrangement: PanelArrangement? {
        get { self[PanelArrangementKey.self] }
        set { self[PanelArrangementKey.self] = newValue }
    }
}

private struct CurrentWidgetIDKey: EnvironmentKey {
    static let defaultValue: WidgetID? = nil
}

extension EnvironmentValues {
    var currentWidgetID: WidgetID? {
        get { self[CurrentWidgetIDKey.self] }
        set { self[CurrentWidgetIDKey.self] = newValue }
    }
}

private struct HidePanelKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var hidePanel: (() -> Void)? {
        get { self[HidePanelKey.self] }
        set { self[HidePanelKey.self] = newValue }
    }
}

private struct PasteIntoPreviousAppKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var pasteIntoPreviousApp: (() -> Void)? {
        get { self[PasteIntoPreviousAppKey.self] }
        set { self[PasteIntoPreviousAppKey.self] = newValue }
    }
}

/// How the lanes tell the editor where their slots ended up.
struct DropZonePreference: PreferenceKey {
    static var defaultValue: [PanelEditor.DropZone] = []

    static func reduce(value: inout [PanelEditor.DropZone], nextValue: () -> [PanelEditor.DropZone]) {
        value += nextValue()
    }
}

/// Header frames — what the long-press to edit hit-tests against.
struct HeaderFrame: Equatable {
    let id: WidgetID
    let frame: CGRect
}

struct HeaderFramePreference: PreferenceKey {
    static var defaultValue: [HeaderFrame] = []
    static func reduce(value: inout [HeaderFrame], nextValue: () -> [HeaderFrame]) {
        value += nextValue()
    }
}
