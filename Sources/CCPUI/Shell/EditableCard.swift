// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// A widget in its lane, plus everything edit mode adds to it: the wiggle, the
/// badge that takes it off the panel, and the drag that moves it.
///
/// The card also reports where it ended up, which is what edit mode hit-tests
/// against — a card knows its own frame, and nothing above it in the view tree
/// does.
struct EditableCard: View {
    let slot: LaneSlot
    let lane: Int
    let arrangement: PanelArrangement
    let editor: PanelEditor

    /// The card is drawn at the finger while it is in the air, so its lane
    /// holds an empty space of the same size instead — the gap the other
    /// cards close over.
    private var isInTheAir: Bool { editor.lifted?.id == slot.id }

    var body: some View {
        LaneSlotCard(slot: slot)
            .wiggling(editor.isEditing && !isInTheAir)
            .overlay(alignment: .topLeading) { removeBadge }
            // The whole card, badge included: what a lifted card leaves in its
            // lane is a gap, and a gap with a remove button floating in it is
            // a control belonging to nothing.
            .opacity(isInTheAir ? 0 : 1)
            .background { frameReporter }
            .gesture(longPressToEdit)
            .gesture(dragToRearrange)
    }

    @ViewBuilder private var removeBadge: some View {
        if editor.isEditing {
            Button {
                withAnimation(.snappy) { arrangement.remove(slot.id) }
            } label: {
                // A dark glyph on a light disc, not the other way round: the
                // badge sits on a card that is already dark, and a dimmed
                // circle on it reads as a stray dash rather than a control.
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.black.opacity(0.75), .white)
                    .shadow(color: .cardShadow, radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .offset(x: -Space.half, y: -Space.half)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("Remove \(slot.title)")
        }
    }

    private var frameReporter: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: DropZonePreference.self,
                value: [PanelEditor.DropZone(id: slot.id, lane: lane, frame: proxy.frame(in: .panel))]
            )
        }
    }

    private var longPressToEdit: some Gesture {
        LongPressGesture(minimumDuration: 0.4).onEnded { _ in
            withAnimation(.snappy) { editor.startEditing() }
        }
    }

    /// Rearranges as it goes rather than at the end: the lanes reflow under the
    /// card in the air, so what the panel looks like mid-drag is what letting
    /// go would leave behind.
    private var dragToRearrange: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .panel)
            .onChanged { value in
                guard editor.isEditing else { return }
                if editor.lifted == nil {
                    editor.lift(slot.id, at: value.startLocation)
                }
                editor.drag(to: value.location)
                moveToLanding()
            }
            .onEnded { _ in
                guard editor.lifted != nil else { return }
                withAnimation(.snappy) { editor.drop() }
            }
    }

    private func moveToLanding() {
        guard
            let lifted = editor.lifted,
            let landing = editor.landing(laneCount: arrangement.lanes.count)
        else { return }

        withAnimation(.snappy(duration: 0.28)) {
            switch landing {
            case .into(let lane, let index):
                arrangement.move(lifted.id, toLane: lane, at: index)
            case .newLane(let lane):
                arrangement.move(lifted.id, toNewLaneAt: lane)
            }
        }
    }
}
