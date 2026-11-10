// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// The handle a card is resized by: bottom-leading corner, edit mode only.
///
/// Leading, because the panel is pinned to the screen's right edge: a card's
/// trailing edge never moves, so the corner that can follow the pointer is
/// the leading one — drag left to widen, down to grow. It is a mark rather
/// than a button — the iPadOS windowing resize tick, a short rounded corner
/// hugging the card's own. The drag itself belongs to the panel-level
/// gesture, which hit-tests the press against the frames this reports: a
/// per-card gesture never reliably saw the touch, and the panel's already
/// gets every one. VoiceOver users get the same sizes as actions.
struct ResizeGrip: View {
    let slot: LaneSlot
    let arrangement: PanelArrangement
    let editor: PanelEditor

    @State private var isHovered = false

    var body: some View {
        CornerTick()
            .stroke(.white, style: StrokeStyle(lineWidth: Stroke.resizeTick, lineCap: .round))
            // The tick is drawn for a bottom-trailing corner; mirrored, it
            // hugs the bottom-leading one.
            .scaleEffect(x: -1, y: 1)
            // The mark is small and the target is not: a full 44pt box in the
            // corner, so the finger can land anywhere near the edge. Its outer
            // corner sits exactly on the card's, which is what lets the arc
            // hug the card's own rounding.
            .frame(width: Layout.resizeTouchTarget, height: Layout.resizeTouchTarget)
            .contentShape(Rectangle())
            // White on glass needs a shadow to read over a light wallpaper.
            .shadow(color: .cardShadow, radius: 2, y: 1)
            // The tick answers the pointer before the press: slightly larger
            // on hover, on a spring with a little give that still settles
            // fast. Anchored to the corner so the growth never leaves the
            // edge it hugs.
            .scaleEffect(isHovered ? Layout.resizeGripHoverScale : 1, anchor: .bottomLeading)
            .animation(.spring(response: 0.32, dampingFraction: 0.55), value: isHovered)
            .onHover { isHovered = $0 }
            .background { gripReporter }
            .help("Drag to resize")
            .accessibilityLabel("Resize \(slot.title)")
            .accessibilityValue(accessibilitySize)
            .accessibilityAction(named: "Make wider") { step(by: CGSize(width: 1, height: 0)) }
            .accessibilityAction(named: "Make narrower") { step(by: CGSize(width: -1, height: 0)) }
            .accessibilityAction(named: "Make taller") { step(by: CGSize(width: 0, height: 1)) }
            .accessibilityAction(named: "Make shorter") { step(by: CGSize(width: 0, height: -1)) }
    }

    /// What VoiceOver steps from: the stored size — never the drawn one, which
    /// a smaller display may have fitted narrower — or, for a card never
    /// resized, the size it is showing.
    private var drawnSize: CGSize? {
        slot.storedSize ?? editor.zones.first { $0.id == slot.id }?.frame.size
    }

    private var accessibilitySize: String {
        guard let size = drawnSize else { return "" }
        return "\(Int(size.width)) by \(Int(size.height)) points"
    }

    /// One step from the drawn size, through the commit path — so the
    /// keyboard and VoiceOver actions meet the same clamp as the drag.
    private func step(by delta: CGSize) {
        guard let size = drawnSize else { return }
        commitResize(
            CGSize(
                width: size.width + delta.width * PanelEditor.accessibilityStep,
                height: size.height + delta.height * PanelEditor.accessibilityStep
            ),
            of: slot.id, arrangement: arrangement, editor: editor
        )
    }

    private var gripReporter: some View {
        GeometryReader { proxy in
            // The touch area overshoots the drawn box on every side: the
            // finger aims at the card's corner, not at the box, and
            // near-misses must land. The panel hit-tests this frame, not the
            // view's own hit-testing, so `contentShape` above cannot do it.
            Color.clear.preference(
                key: GripFramePreference.self,
                value: [GripFrame(
                    id: slot.id,
                    frame: proxy.frame(in: .panel).insetBy(
                        dx: -Layout.resizeGripOvershoot,
                        dy: -Layout.resizeGripOvershoot
                    )
                )]
            )
        }
    }
}

/// The one resize commit: the drag's release and the VoiceOver step both go
/// through here, so the clamp lives in exactly one place — the same one the
/// live drag draws through, so what the finger parked at is what lands.
/// Returns whether the size landed; only a card no longer on the panel
/// refuses.
@discardableResult
@MainActor
func commitResize(
    _ size: CGSize, of id: WidgetID,
    arrangement: PanelArrangement, editor: PanelEditor
) -> Bool {
    guard let lane = arrangement.layout.position(of: id)?.lane,
          let maxWidth = editor.maxLaneWidth(for: lane, laneWidths: arrangement.laneWidths)
    else { return false }
    let fit = PanelEditor.clampedSize(size, maxWidth: maxWidth)
    arrangement.resize(id, to: CustomWidgetSize(width: Double(fit.width), height: Double(fit.height)))
    return true
}

/// Where the resize grips are, in panel coordinates. The panel-level drag
/// gesture reads these the way it reads header frames: a press starting on a
/// grip begins a resize, and lifting the card under it would answer a resize
/// with a reorder.
struct GripFrame: Equatable {
    let id: WidgetID
    let frame: CGRect
}

struct GripFramePreference: PreferenceKey {
    static var defaultValue: [GripFrame] = []
    static func reduce(value: inout [GripFrame], nextValue: () -> [GripFrame]) {
        value += nextValue()
    }
}
