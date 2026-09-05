// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// The handle a card is resized by: bottom-trailing corner, edit mode only.
///
/// Dragging counts whole steps of the widget's base size — one lane-unit
/// right is one width step, one base-height down is one height step — and the
/// lane draws the preview live. On release the span commits once, or snaps
/// back when a wider lane would hang off the screen.
///
/// The drag previews in the editor and never touches the layout mid-gesture,
/// so the card stays in its lane and this per-card gesture's view identity
/// stays put — which is why a per-card gesture is safe here and would hang a
/// reorder. VoiceOver users get the same steps as actions.
struct ResizeGrip: View {
    let slot: LaneSlot
    let lane: Int
    let arrangement: PanelArrangement
    let editor: PanelEditor

    /// The step the drag counts in. The widget's own base size, not its
    /// current one: steps stay the same width wherever the drag starts.
    private var baseSize: CGSize {
        CGSize(
            width: Layout.laneWidth,
            height: slot.instance?.descriptor.size.height ?? WidgetSize.regular.height
        )
    }

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(Space.half)
            .contentShape(Rectangle())
            .background { gripReporter }
            .gesture(resizeGesture)
            .accessibilityLabel("Resize \(slot.title)")
            .accessibilityValue("\(slot.span.width) by \(slot.span.height)")
            .accessibilityAction(named: "Make wider") { step(by: CGSize(width: 1, height: 0)) }
            .accessibilityAction(named: "Make narrower") { step(by: CGSize(width: -1, height: 0)) }
            .accessibilityAction(named: "Make taller") { step(by: CGSize(width: 0, height: 1)) }
            .accessibilityAction(named: "Make shorter") { step(by: CGSize(width: 0, height: -1)) }
    }

    private var resizeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if editor.resizePreview == nil {
                    editor.beginResize(slot.id, from: slot.span)
                }
                // A second finger's drag never steers the preview already in
                // flight — beginResize refused to preempt it above.
                guard editor.resizePreview?.id == slot.id else { return }
                editor.updateResize(translation: value.translation, from: slot.span, baseSize: baseSize)
            }
            .onEnded { _ in
                defer { editor.endResize() }
                guard let preview = editor.resizePreview, preview.id == slot.id else { return }
                commit(preview.span)
            }
    }

    /// One step from the stored span, through the commit path — so the
    /// keyboard and VoiceOver actions meet the same refusal rule as the drag.
    private func step(by delta: CGSize) {
        commit(WidgetSpan(
            width: slot.span.width + Int(delta.width),
            height: slot.span.height + Int(delta.height)
        ))
    }

    /// The span through the commit path: refused when a wider lane would hang
    /// off the screen, which snaps the preview back instead.
    private func commit(_ span: WidgetSpan) {
        if span.width != slot.span.width {
            let offered = slot.resized(to: span).width
            guard editor.canResizeLane(lane, to: offered, laneWidths: arrangement.laneWidths) else { return }
        }
        arrangement.resize(slot.id, to: span)
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

/// Where the resize grips are, in panel coordinates. The panel-level drag
/// gesture reads these the way it reads header frames: a press starting on a
/// grip belongs to the grip, and lifting the card under it would answer a
/// resize with a reorder.
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
