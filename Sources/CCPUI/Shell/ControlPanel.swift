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
        .onPreferenceChange(DropZonePreference.self) { zones in
            editor.zones = zones
        }
        .overlay(alignment: .topLeading) { cardInTheAir }
        .animation(.snappy(duration: 0.28), value: arrangement.layout)
        .animation(.snappy(duration: 0.28), value: editor.isEditing)
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
                NewLaneTarget()
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
            LaneSlotCard(slot: slot, isRaised: true)
                .frame(width: lifted.size.width, height: lifted.size.height)
                .scaleEffect(1.04)
                .offset(
                    x: editor.fingerAt.x - lifted.grab.width,
                    y: editor.fingerAt.y - lifted.grab.height
                )
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

    var body: some View {
        VStack(spacing: Space.oneHalf) {
            ForEach(slots) { slot in
                EditableCard(slot: slot, lane: lane, arrangement: arrangement, editor: editor)
                    .frame(width: Layout.laneWidth)
                    .frame(minHeight: slot.height)
                    // Ideal height, then rigid: without this a lane's spare
                    // room is shared out among its cards and three widgets
                    // that each declared a different size come out the same.
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Lanes are as tall as the tallest of them, and without something
            // to absorb the slack a short lane hands it to its widgets instead
            // — three cards that each declared a different size come out the
            // same height.
            Spacer(minLength: 0)
        }
    }
}

/// Where a new lane would go. Dashed rather than drawn as glass, because it is
/// a place rather than a thing.
private struct NewLaneTarget: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(
                Color.cardStroke,
                style: StrokeStyle(lineWidth: Stroke.hairline, dash: [Space.one, Space.half])
            )
            .frame(width: Layout.laneWidth)
            .frame(maxHeight: .infinity)
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
