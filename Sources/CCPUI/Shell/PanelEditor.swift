// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
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
    ///
    /// Seeded with the main screen, not infinity: the desk draws stickies
    /// before the first show, and an infinite seat put their centers at
    /// x ≈ 1.8e308, which took a clip layer NaN and the app down with it
    /// (ccp-2esx). The fallback matches the shell's no-screen rect precedent
    /// (ShelfWindowController, QuickTogglesWidget); the first show still
    /// re-seats onto the real display.
    public var displayWidth: CGFloat = NSScreen.main?.visibleFrame.width ?? 1440
    /// The seat's visible height, same source and seeding. What the website
    /// bar reads to flip above a card near the display's bottom — the view
    /// layer must not go hunting screens itself.
    public var displayHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 900

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
    // A resize draws continuously and commits once, on release — the same
    // one-mutation shape as a drag. Mutating the layout per pixel would
    // re-resolve the arrangement and re-schedule the autosave every frame; a
    // preview is just a size the lane draws instead of the stored one until
    // the finger comes up. What the finger shows is what the release stores:
    // both go through `clampedSize`, and nothing rounds, steps, or snaps.

    /// The card under the grip and the size it is being dragged to, or `nil`
    /// when no grip is held.
    public private(set) var resize: Resize?

    public struct Resize: Equatable {
        let id: WidgetID
        /// The size the card was drawn at when the press landed — measured,
        /// not stored, so the first frame of a drag is exactly the card the
        /// user grabbed and never a jump to some other idea of its size.
        let start: CGSize
        /// The widest the card may draw: the room its lane has beside the
        /// others, taken at the press. The other lanes cannot change while
        /// the grip is held, so neither can this.
        let maxWidth: CGFloat
        /// The size the card draws at now, and lands at on release.
        var size: CGSize
    }

    /// The smallest a card can be dragged to, in either axis: the grip's own
    /// touch target. Not a widget's opinion of its size — any card can go
    /// this small — only the point below which there would be nothing left
    /// to grab it back by.
    static let minimumCardSize: CGFloat = Layout.resizeTouchTarget

    /// One VoiceOver step: visible, but fine enough to land where meant.
    static let accessibilityStep: CGFloat = 40

    /// `size` held to what the panel can draw: never wider than `maxWidth`,
    /// never under the grab floor. Height has no ceiling — a lane taller than
    /// the display scrolls.
    static func clampedSize(_ size: CGSize, maxWidth: CGFloat) -> CGSize {
        CGSize(
            width: max(min(size.width, maxWidth), minimumCardSize),
            height: max(size.height, minimumCardSize)
        )
    }

    public func beginResize(_ id: WidgetID, from start: CGSize, maxWidth: CGFloat) {
        // One grip at a time: a second finger never preempts the drag already
        // in flight, or the two releases wipe each other's preview out.
        guard resize == nil else { return }
        resize = Resize(id: id, start: start, maxWidth: maxWidth, size: start)
    }

    /// The drag's translation in screen points since the press.
    ///
    /// The grip sits on the card's bottom-leading corner and the panel is
    /// pinned top-right, so dragging left widens and dragging down grows:
    /// the card's trailing edge stays where it is and its leading edge — the
    /// corner under the finger — moves with the pointer, point for point.
    /// Only a changed size lands: identical ticks must not re-draw the lane.
    public func updateResize(translation: CGSize) {
        guard let resize else { return }
        let size = Self.clampedSize(
            CGSize(
                width: resize.start.width - translation.width,
                height: resize.start.height + translation.height
            ),
            maxWidth: resize.maxWidth
        )
        guard size != resize.size else { return }
        self.resize?.size = size
    }

    public func endResize() { resize = nil }

    /// The size to draw `id` at while its grip is held, or `nil` for every
    /// other card and whenever no grip is held.
    public func drawSize(for id: WidgetID) -> CGSize? {
        guard let resize, resize.id == id else { return nil }
        return resize.size
    }

    /// The widest `lane` may draw while the other lanes stay put — the commit
    /// and the live draw clamp to this. Measured against the other lanes as
    /// drawn, fitted to this display, so a layout from a wider one still
    /// leaves the lane its own drawn width to start from. Nil when the lane
    /// index is stale.
    public func maxLaneWidth(for lane: Int, laneWidths: [CGFloat]) -> CGFloat? {
        guard laneWidths.indices.contains(lane) else { return nil }
        var others = Layout.fittedLaneWidths(laneWidths, inWidth: displayWidth)
        others.remove(at: lane)
        return Layout.maxLaneWidth(beside: others, inWidth: displayWidth)
    }

    /// The lane a drop would open, if the ghost is hovering a gap and the
    /// display has room for another column — `nil` over a lane, when the
    /// display is full, or with nothing in the air.
    public func offeredNewLaneAt(beside laneWidths: [CGFloat]) -> Int? {
        guard case .newLane(let at) = previewLanding, canAddLane(beside: laneWidths) else { return nil }
        return at
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

        // Outside every lane's x-range is the column the panel would grow
        // into: left of everything, right of everything, or the gutter
        // between two lanes. The insertion index is the count of lanes fully
        // left of the ghost — every lane minus those reaching past it — which
        // is the layout index a new lane opens at: visual order matches
        // layout order, so lanes 0..<k sit left of gap k.
        guard !source.isEmpty else { return nil }
        let lanes = Set(source.map(\.lane))
        let insertAt = lanes.subtracting(source.filter { $0.frame.maxX >= center.x }.map(\.lane)).count
        // A card alone in its lane has no adjacent gap to open: lifting it
        // empties the lane and the insert collapses straight back, so the
        // commit is a no-op the preview must not promise.
        if let home = source.first(where: { $0.id == lifted.id }),
           source.filter({ $0.lane == home.lane }).count == 1,
           insertAt == home.lane || insertAt == home.lane + 1 { return nil }
        return canAddLane(beside: laneWidths) ? .newLane(at: insertAt) : nil
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

/// Frames of floating UI hung outside card frames, in panel coordinates.
/// A website nav bar hangs off its card's outer edge — outside every card
/// frame — so the backdrop hit-test must count it as the panel's, otherwise a
/// click on the bar reads as backdrop and dismisses under the finger.
/// Reported only while visible; hidden overflow hit-tests nothing. Named for
/// the relationship, not the widget: the next floating control reuses this
/// rather than growing its own preference.
struct PanelOverflowFramePreference: PreferenceKey {
    static var defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value += nextValue()
    }
}

/// Raises a view above its siblings while anything inside it reports an
/// overflow frame. `zIndex` orders only siblings, so the card raises itself in
/// its lane and the lane in the panel: otherwise a bar hung past the card's
/// edge draws under the next card or lane, which then takes its clicks.
struct RaisedWhileOverflowing: ViewModifier {
    @State private var isOverflowing = false

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(PanelOverflowFramePreference.self) { isOverflowing = !$0.isEmpty }
            .zIndex(isOverflowing ? 1 : 0)
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

/// The lanes' box in panel space. The window is screen-sized and lets clicks
/// through outside the panel's own content, so the controller hit-tests the
/// pointer against this to decide what falls through.
struct LanesFramePreference: PreferenceKey {
    static var defaultValue: CGRect?
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}
