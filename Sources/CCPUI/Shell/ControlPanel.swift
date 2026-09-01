// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// Everything inside the glass: vertical lanes of widget cards, and the edit
/// mode that rearranges them.
///
/// The panel draws the arrangement and holds no opinion about how it came to
/// be: reading it off disk and resolving it against the registry happens
/// before this, and starting the widgets it placed belongs to the arrangement
/// itself. What happens here is the part that is only true on screen — where
/// the cards are, and which one is currently in the air.
public struct ControlPanel: View {
    private let arrangement: PanelArrangement
    private let editor: PanelEditor

    @GestureState private var isGestureActive = false

    init(arrangement: PanelArrangement, editor: PanelEditor) {
        self.arrangement = arrangement
        self.editor = editor
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: Space.oneHalf) {
            if editor.isEditing { EditingBar(arrangement: arrangement, editor: editor) }
            lanes
        }
        .padding(Space.oneHalf)
        .coordinateSpace(.panel)
        .contentShape(Rectangle())
        .gesture(panelDrag)
        .onPreferenceChange(DropZonePreference.self) { zones in
            editor.zones = zones
        }
        .overlay(alignment: .topLeading) { cardInTheAir }
        .animation(editor.isDragging ? nil : .snappy(duration: 0.28), value: arrangement.layout)
        .animation(.snappy(duration: 0.28), value: editor.isEditing)
        .animation(.snappy(duration: 0.2), value: editor.previewLanding)
        .onChange(of: isGestureActive) { _, isActive in
            // DragGesture .onEnded is not called when the system cancels the
            // gesture (second finger, notification center). GestureState
            // resets automatically on cancel, so a hanging `lifted` is the
            // signal that onEnded never fired.
            if !isActive, editor.isDragging {
                editor.cancel()
            }
        }
    }

    /// One gesture for the whole panel, not per-card. A per-card gesture is
    /// attached to a view that moves between lanes; when the lane mutates the
    /// view is recreated and the in-flight gesture is cancelled mid-drag,
    /// leaving `lifted` hanging. A panel-level gesture lives on the stable
    /// container and hit-tests against the frozen snapshot.
    private var panelDrag: some Gesture {
        DragGesture(minimumDistance: Space.half, coordinateSpace: .panel)
            .updating($isGestureActive) { _, state, _ in state = true }
            .onChanged { value in
                guard editor.isEditing else { return }
                if editor.lifted == nil {
                    // Hit-test the start location against frozen-or-live zones.
                    let hit = editor.zones.first { $0.frame.contains(value.startLocation) }
                    guard let hit else { return }
                    editor.lift(hit.id, at: value.startLocation)
                }
                editor.drag(to: value.location, laneCount: arrangement.lanes.count)
            }
            .onEnded { _ in
                guard let lifted = editor.lifted else { return }
                // previewLanding was computed from the frozen snapshot on each
                // drag frame; commit a single layout mutation on drop rather
                // than on every pixel — that is what removes the per-frame
                // thrash and window resize while dragging.
                if let landing = editor.previewLanding {
                    withAnimation(.snappy(duration: 0.28)) {
                        switch landing {
                        case .into(let lane, let index):
                            arrangement.move(lifted.id, toLane: lane, at: index)
                        case .newLane(let lane):
                            arrangement.move(lifted.id, toNewLaneAt: lane)
                        }
                    }
                }
                editor.drop()
            }
    }

    private var lanes: some View {
        HStack(alignment: .top, spacing: Space.oneHalf) {
            // A lane that doesn't exist yet, offered while something is in the
            // air to put in it and the display has room for another column
            // (ccp-p6g). It leads rather than trails because the panel is
            // pinned to the right of the screen: a column opening on that side
            // would shove every card sideways under the finger holding one.
            // It is never in the layout — an empty lane is exactly what
            // `normalized()` closes up.
            if editor.isOfferingNewLane(laneCount: arrangement.lanes.count) {
                NewLaneTarget(isTargeted: editor.previewLanding == .newLane(at: 0))
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            }

            ForEach(arrangement.lanes.indices, id: \.self) { index in
                WidgetLane(lane: index, slots: arrangement.lanes[index], arrangement: arrangement, editor: editor)
            }
        }
    }

    /// The dragged card, drawn once at the finger rather than in the lane it
    /// came from — the lane keeps its place as a gap that the other cards
    /// close over as the layout reorders beneath it.
    @ViewBuilder private var cardInTheAir: some View {
        if let lifted = editor.lifted, let slot = arrangement.slot(for: lifted.id) {
            let offset = lifted.offset(at: editor.fingerAt)
            LaneSlotCard(slot: slot, isRaised: true)
                .frame(width: lifted.size.width, height: lifted.size.height)
                .scaleEffect(PanelEditor.Lifted.scale)
                .offset(x: offset.width, y: offset.height)
                .allowsHitTesting(false)
        }
    }
}

/// The two controls edit mode needs: something to add with, and a way out.
private struct EditingBar: View {
    let arrangement: PanelArrangement
    let editor: PanelEditor

    @State private var isShowingGallery = false

    var body: some View {
        HStack(spacing: Space.one) {
            Button {
                isShowingGallery = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Add a widget")
            .popover(isPresented: $isShowingGallery, arrowEdge: .bottom) {
                WidgetGallery(arrangement: arrangement) { isShowingGallery = false }
            }

            Button("Done") {
                withAnimation(.snappy) { editor.stopEditing() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct WidgetLane: View {
    let lane: Int
    let slots: [LaneSlot]
    let arrangement: PanelArrangement
    let editor: PanelEditor

    private var visibleSlots: [LaneSlot] {
        guard let lifted = editor.lifted else { return slots }
        return slots.filter { $0.id != lifted.id }
    }

    /// The gap the lifted card would fill if dropped here. While the finger
    /// is down the real layout is untouched (one mutation on drop, not per
    /// pixel), so a placeholder gap is what tells the eye where the drop
    /// would land without the thrash of re-laying out every frame.
    private var gapIndex: Int? {
        guard let landing = editor.previewLanding else { return nil }
        if case .into(let targetLane, let index) = landing, targetLane == lane {
            return index
        }
        return nil
    }

    var body: some View {
        VStack(spacing: Space.oneHalf) {
            ForEach(Array(visibleSlots.enumerated()), id: \.element.id) { offset, slot in
                if gapIndex == offset { dropGap }
                EditableCard(slot: slot, lane: lane, arrangement: arrangement, editor: editor)
                    .frame(width: Layout.laneWidth)
                    .frame(minHeight: slot.height)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if gapIndex == visibleSlots.count { dropGap }
            // When the lane is empty and the gap is the only thing in it,
            // the ForEach above renders nothing — still show the gap.
            if visibleSlots.isEmpty, gapIndex == nil, editor.isDragging,
               editor.previewLanding == nil, slots.contains(where: { $0.id == editor.lifted?.id }) {
                // The lifted card came from this lane and the finger is not
                // over a valid lane — keep the lane's height stable rather
                // than collapsing it mid-drag.
                Color.clear.frame(height: editor.lifted?.size.height ?? 0)
            }
            Spacer(minLength: 0)
        }
    }

    private var dropGap: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(
                Color.dropGapStroke,
                style: StrokeStyle(lineWidth: Stroke.hairline, dash: [Space.one, Space.half])
            )
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Color.dropGapFill)
            )
            .frame(width: Layout.laneWidth, height: editor.lifted?.size.height ?? WidgetSize.compact.height)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

/// Where a new lane would go. Dashed rather than drawn as glass, because it is
/// a place rather than a thing.
private struct NewLaneTarget: View {
    var isTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(
                isTargeted ? Color.newLaneStrokeTargeted : Color.cardStroke,
                style: StrokeStyle(lineWidth: isTargeted ? 2 : Stroke.hairline, dash: [Space.one, Space.half])
            )
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(isTargeted ? Color.newLaneFillTargeted : Color.clear)
            )
            .frame(width: Layout.laneWidth)
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.15), value: isTargeted)
            .accessibilityLabel("New lane")
    }
}

struct LaneSlotCard: View {
    let slot: LaneSlot
    var isRaised = false

    var body: some View {
        switch slot {
        case .widget(let widget): widget.view
        case .unavailable(let id): UnavailableWidgetCard(id: id)
        }
    }
}

extension LaneSlot {
    /// A slot standing in for a widget this build doesn't have has no
    /// descriptor to ask, and the smallest card is the least the lane's shape
    /// can be wrong by.
    var height: CGFloat {
        switch self {
        case .widget(let widget): widget.descriptor.size.height
        case .unavailable: WidgetSize.compact.height
        }
    }

    /// What to call this in a label — the widget's own name, or the id, which
    /// is all a slot standing in for an absent widget has.
    var title: String {
        switch self {
        case .widget(let widget): widget.descriptor.title
        case .unavailable(let id): id.rawValue
        }
    }
}
