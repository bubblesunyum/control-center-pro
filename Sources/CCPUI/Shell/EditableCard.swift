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
            .environment(\.currentWidgetID, slot.id)
            .wiggling(editor.isEditing && !isInTheAir)
            .overlay(alignment: .topLeading) { removeBadge }
            .overlay(alignment: .bottomTrailing) { resizeGrip }
            // The whole card, badge included: what a lifted card leaves in its
            // lane is a gap, and a gap with a remove button floating in it is
            // a control belonging to nothing. Hit-testing is handled by the
            // panel-level gesture (frozen zones), not per-card — a per-card
            // gesture dies when its view moves between lanes and hangs the
            // drag in the air.
            .opacity(isInTheAir ? 0 : 1)
            .background { frameReporter }
            .contentShape(Rectangle())
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

    /// The resize grip: a handle on the card's bottom-trailing corner, in edit
    /// mode only, on cards that take part in resizing. The panel-level gesture
    /// leaves presses that start on the grip alone (see `GripFramePreference`
    /// in ResizeGrip.swift), so the two never fight over one touch.
    @ViewBuilder private var resizeGrip: some View {
        if editor.isEditing, !isInTheAir,
           let widget = slot.instance, widget.descriptor.size.isResizable {
            ResizeGrip(slot: slot, lane: lane, arrangement: arrangement, editor: editor)
        }
    }
}
