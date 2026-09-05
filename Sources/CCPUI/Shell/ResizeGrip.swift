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

    var body: some View {
        CornerTick()
            .stroke(.secondary, style: StrokeStyle(lineWidth: Stroke.resizeTick, lineCap: .round, lineJoin: .round))
            .frame(width: Layout.resizeTickLength, height: Layout.resizeTickLength)
            // A generous target around a small mark. Inset a full step inside
            // the corner: flush to the edge, the tick straddles the card's
            // hairline and reads as a broken border rather than a mark.
            .padding(Space.oneHalf)
            .contentShape(Rectangle())
            .background { gripReporter }
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
            Color.clear.preference(
                key: GripFramePreference.self,
                value: [GripFrame(id: slot.id, frame: proxy.frame(in: .panel))]
            )
        }
    }
}

/// A short rounded corner: a horizontal arm along the bottom meeting a
/// vertical arm up the trailing edge.
private struct CornerTick: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
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
        let offered = slot.resized(to: span).width
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
