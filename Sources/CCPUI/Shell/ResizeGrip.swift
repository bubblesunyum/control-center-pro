// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// The handle a card is resized by: bottom-trailing corner, edit mode only.
///
/// It is a mark rather than a button — the iPadOS windowing resize tick, a
/// short rounded corner hugging the card's own. The drag itself belongs to
/// the panel-level gesture, which hit-tests the press against the frames this
/// reports: a per-card gesture never reliably saw the touch, and the panel's
/// already gets every one. VoiceOver users get the same steps as actions.
struct ResizeGrip: View {
    let slot: LaneSlot
    let lane: Int
    let arrangement: PanelArrangement
    let editor: PanelEditor

    @State private var isHovered = false

    var body: some View {
        CornerTick()
            .stroke(.white, style: StrokeStyle(lineWidth: Stroke.resizeTick, lineCap: .round))
            // The mark is small and the target is not: a full 44pt box in the
            // corner, so the finger can land anywhere near the edge. Its outer
            // corner sits exactly on the card's, which is what lets the arc
            // below hug the card's own rounding.
            .frame(width: Layout.resizeTouchTarget, height: Layout.resizeTouchTarget)
            .contentShape(Rectangle())
            // White on glass needs a shadow to read over a light wallpaper.
            .shadow(color: .cardShadow, radius: 2, y: 1)
            // The tick answers the pointer before the press: slightly larger
            // on hover, on a spring with a little give that still settles
            // fast. Anchored to the corner so the growth never leaves the
            // edge it hugs.
            .scaleEffect(isHovered ? Layout.resizeGripHoverScale : 1, anchor: .bottomTrailing)
            .animation(.spring(response: 0.32, dampingFraction: 0.55), value: isHovered)
            .onHover { isHovered = $0 }
            .background { gripReporter }
            .help("Drag to resize")
            .accessibilityLabel("Resize \(slot.title)")
            .accessibilityValue("\(slot.span.width) by \(slot.span.height)")
            .accessibilityAction(named: "Make wider") { step(by: CGSize(width: 1, height: 0)) }
            .accessibilityAction(named: "Make narrower") { step(by: CGSize(width: -1, height: 0)) }
            .accessibilityAction(named: "Make taller") { step(by: CGSize(width: 0, height: 1)) }
            .accessibilityAction(named: "Make shorter") { step(by: CGSize(width: 0, height: -1)) }
    }

    /// One step from the stored span, through the commit path — so the
    /// keyboard and VoiceOver actions meet the same refusal rule as the drag.
    private func step(by delta: CGSize) {
        commitResize(
            WidgetSpan(
                width: slot.span.width + Int(delta.width),
                height: slot.span.height + Int(delta.height)
            ),
            of: slot, in: lane, arrangement: arrangement, editor: editor
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

/// A short arc concentric with the card's own corner: the grip box's outer
/// corner sits exactly on the card's, so centering the arc one card-radius in
/// hugs the edge. Inset half a step inside the hairline — flush, it would read
/// as a broken border rather than a mark.
private struct CornerTick: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.maxX - Radius.card, y: rect.maxY - Radius.card),
            radius: Radius.card - Space.half,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        return path
    }
}

/// The one resize commit: the drag's release and the VoiceOver step both go
/// through here, so the refusal rule lives in exactly one place.
///
/// A wider lane that would hang off the screen is refused rather than
/// written, and the preview snaps back instead. Returns whether the span
/// landed.
@discardableResult
@MainActor
func commitResize(
    _ span: WidgetSpan, of slot: LaneSlot, in lane: Int,
    arrangement: PanelArrangement, editor: PanelEditor
) -> Bool {
    if span.width != slot.span.width {
        // Measure the lane as it would be — gutters and all — not the slot
        // alone, which is narrower than the lane by the shell's gutters.
        guard arrangement.lanes.indices.contains(lane) else { return false }
        let offered = arrangement.lanes[lane].map { $0.id == slot.id ? $0.resized(to: span) : $0 }.width
        guard editor.canResizeLane(lane, to: offered, laneWidths: arrangement.laneWidths) else {
            return false
        }
    }
    arrangement.resize(slot.id, to: span)
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
