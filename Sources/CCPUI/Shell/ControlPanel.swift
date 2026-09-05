// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

private struct IsPanelEditingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isPanelEditing: Bool {
        get { self[IsPanelEditingKey.self] }
        set { self[IsPanelEditingKey.self] = newValue }
    }
}

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
    @State private var headerFrames: [HeaderFrame] = []
    @State private var gripFrames: [GripFrame] = []
    @State private var holdTask: Task<Void, Never>?
    @State private var holdWidgetID: WidgetID?

    init(arrangement: PanelArrangement, editor: PanelEditor) {
        self.arrangement = arrangement
        self.editor = editor
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: Space.oneHalf) {
            lanes
        }
        .padding(Space.oneHalf)
        .coordinateSpace(.panel)
        .contentShape(Rectangle())
        .environment(\.isPanelEditing, editor.isEditing)
        .environment(\.panelEditor, editor)
        .environment(\.panelArrangement, arrangement)
        .onPreferenceChange(DropZonePreference.self) { zones in
            editor.zones = zones
        }
        .onPreferenceChange(HeaderFramePreference.self) { frames in
            headerFrames = frames
        }
        .onPreferenceChange(GripFramePreference.self) { frames in
            gripFrames = frames
        }
        .overlay(alignment: .topLeading) { cardInTheAir }
        .overlay { if editor.isShowingGallery { galleryOverlay } }
        .animation(editor.isDragging ? nil : .snappy(duration: 0.28), value: arrangement.layout)
        .animation(.snappy(duration: 0.28), value: editor.isEditing)
        .animation(.snappy(duration: 0.2), value: editor.previewLanding)
        .onChange(of: isGestureActive) { _, isActive in
            // DragGesture .onEnded is not called when the system cancels the
            // gesture (second finger, notification center). GestureState
            // resets automatically on cancel, so a hanging `lifted` is the
            // signal that onEnded never fired.
            if !isActive {
                if editor.isDragging { editor.cancel() }
                // A grip drag the system cancelled never sees onEnded, so its
                // preview would otherwise outlive the gesture.
                editor.endResize()
                // Hold timer would otherwise fire after the finger is gone and
                // re-enter edit with no finger down (or block the next hold
                // because holdTask stays non-nil while completed).
                holdTask?.cancel()
                holdTask = nil
                holdWidgetID = nil
            }
        }
        .onDisappear {
            holdTask?.cancel()
            holdTask = nil
            holdWidgetID = nil
            // A grip drag the system cancelled never sees onEnded, so its
            // preview would otherwise outlive the panel.
            editor.endResize()
        }
        // Always installed — a conditional `if isEditing { base.gesture(...) } else { base }`
        // rebuilds the view tree when editing toggles and the first drag's
        // GestureState is still wired to the old identity, so the first
        // click-drag after entering edit mode never lifts. Keeping the
        // recogniser live and masking it off when not editing lets the Files
        // widget's `.onDrag` reach the row while editing is off, and makes the
        // first reorder drag land. Use simultaneous so a header hold (panel
        // drag when not editing) doesn't block the Files row's onDrag.
        .simultaneousGesture(panelDrag)
    }

    private var galleryOverlay: some View {
        ZStack {
            // Dim behind the gallery — separate from cardShadow (which is for cards).
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.snappy) { editor.isShowingGallery = false } }
            GlassCard(isRaised: true) {
                WidgetGallery(arrangement: arrangement) { withAnimation(.snappy) { editor.isShowingGallery = false } }
            }
            .frame(width: Layout.laneWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    /// One gesture for the whole panel, not per-card. A per-card gesture is
    /// attached to a view that moves between lanes; when the lane mutates the
    /// view is recreated and the in-flight gesture is cancelled mid-drag,
    /// leaving `lifted` hanging. A panel-level gesture lives on the stable
    /// container and hit-tests against the frozen snapshot. When not editing,
    /// a 0.5s hold on a header enters edit and lifts in one press so the
    /// same hold can drag without re-clicking.
    private var panelDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .panel)
            .updating($isGestureActive) { _, state, _ in state = true }
            .onChanged { value in
                // Gallery is a modal overlay — drags on the dim should not
                // mutate the layout behind it.
                guard !editor.isShowingGallery else { return }
                if editor.isEditing {
                    // A resize in flight steers by translation; a press
                    // starting on a grip begins one. Both return before the
                    // reorder path — answering a resize with a reorder is the
                    // failure these guards exist to prevent. A stale grip
                    // frame with no slot behind it falls through to reorder,
                    // which is what a press on a card means.
                    if editor.resizePreview != nil {
                        editor.updateResize(translation: value.translation)
                        return
                    }
                    if let grip = gripFrames.first(where: { $0.frame.contains(value.startLocation) }),
                       let slot = arrangement.slot(for: grip.id) {
                        editor.beginResize(grip.id, from: slot.span, baseSize: slot.resizeStep)
                        return
                    }
                    // Normal reorder — require a tiny move before lifting to
                    // avoid lifting on a plain click.
                    if editor.lifted == nil {
                        let moved = hypot(value.translation.width, value.translation.height) > Space.half
                        guard moved else { return }
                        guard let hit = editor.zones.first(where: { $0.frame.contains(value.startLocation) }) else { return }
                        editor.lift(hit.id, at: value.startLocation)
                    }
                    editor.drag(to: value.location, laneWidths: arrangement.laneWidths)
                } else {
                    // Not editing: hold on a header to enter edit + lift.
                    // If already lifted via hold, drag (isEditing will be true on next tick, but handle here for the first move after hold).
                    if editor.lifted != nil {
                        editor.drag(to: value.location, laneWidths: arrangement.laneWidths)
                        return
                    }
                    guard let headerHit = headerFrames.first(where: { $0.frame.contains(value.startLocation) }) else { return }
                    let moved = hypot(value.translation.width, value.translation.height) > Space.half

                    // Moved before hold completed — cancel and ignore this press.
                    if moved {
                        holdTask?.cancel()
                        holdTask = nil
                        holdWidgetID = nil
                        return
                    }

                    if holdTask == nil {
                        let startLoc = value.startLocation
                        let widgetID = headerHit.id
                        holdWidgetID = widgetID
                        holdTask = Task {
                            try? await Task.sleep(for: .seconds(0.5))
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                guard !editor.isEditing, editor.lifted == nil else { return }
                                withAnimation(.snappy) { editor.startEditing() }
                                editor.lift(widgetID, at: startLoc)
                            }
                        }
                    }
                }
            }
            .onEnded { _ in
                holdTask?.cancel()
                holdTask = nil
                holdWidgetID = nil
                // A resize commits once, on release — or snaps back when a
                // wider lane would hang off the screen.
                if let preview = editor.resizePreview {
                    editor.endResize()
                    if let slot = arrangement.slot(for: preview.id),
                       let lane = arrangement.layout.position(of: preview.id)?.lane {
                        commitResize(
                            preview.span, of: slot, in: lane,
                            arrangement: arrangement, editor: editor
                        )
                    }
                }
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
            if editor.isOfferingNewLane(beside: arrangement.laneWidths) {
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

/// One item in a lane's flow: a slot, or the gap where the lifted card would
/// land. Keyed by the slot so a card keeps its identity — and its wiggle
/// phase — while the gap moves around it.
@MainActor
private enum LaneCell {
    case slot(LaneSlot)
    /// The gap counts what the lifted card counts: its span's columns, or
    /// nothing when the card is not countable in columns — an app screen
    /// always stands alone, in the preview as in the commit.
    case gap(columns: Int?)

    var key: String {
        switch self {
        case .slot(let slot): "slot-\(slot.id)"
        case .gap: "gap"
        }
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

    /// The lane's grid width in columns, counted off what is drawn — while a
    /// grip is dragged the preview span is what the lane draws, so widening
    /// past a column opens the row the commit would pack into.
    private var units: Int {
        slots.map(editor.previewing).gridUnits
    }

    /// The lane's cells — its visible slots with the drop gap inserted where
    /// the landing says it goes — packed into rows by the lane's grid.
    private var rows: [[LaneCell]] {
        var cells = visibleSlots.map(LaneCell.slot)
        if let gapIndex, let lifted = editor.lifted {
            let counted: Int? = arrangement.slot(for: lifted.id)?.gridColumns ?? nil
            cells.insert(.gap(columns: counted.map { min(max($0, 1), units) }), at: min(gapIndex, cells.count))
        }
        let previewed = cells.map { cell -> Int? in
            switch cell {
            case .slot(let slot): editor.previewing(slot).gridColumns
            case .gap(let columns): columns
            }
        }
        return packRowIndexes(previewed, columns: units).map { $0.map { cells[$0] } }
    }

    var body: some View {
        // While a grip is dragged the lane draws the preview span instead of
        // the stored one; the commit lands on release. Cards keep their
        // stored slots — identity and removal are not preview state.
        let shownWidth = slots.map(editor.previewing).width
        // Leading-aligned: a row narrower than the lane — two 1x cards in a
        // 3-wide grid — starts at the lane's edge rather than centering.
        VStack(alignment: .leading, spacing: Space.oneHalf) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                if row.count == 1, let cell = row.first {
                    cellView(cell, width: shownWidth)
                } else {
                    HStack(alignment: .top, spacing: Space.oneHalf) {
                        ForEach(row, id: \.key) { cell in
                            cellView(cell, width: cellWidth(cell, laneWidth: shownWidth))
                        }
                    }
                }
            }
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

    /// How wide one cell draws: a lone cell stretches to the lane's full
    /// width, as it always has; cells sharing a row split the grid by their
    /// spans, gutters carried by the widths so a 1x card is one lane unit
    /// wherever it sits. Drawn spans, not stored ones — while a grip previews
    /// a new width the row already shows what the commit would pack.
    private func cellWidth(_ cell: LaneCell, laneWidth: CGFloat) -> CGFloat {
        switch cell {
        case .slot(let slot):
            editor.previewing(slot).gridColumns.map { Layout.gridWidth(units: $0) } ?? laneWidth
        case .gap(let columns):
            columns.map { Layout.gridWidth(units: $0) } ?? laneWidth
        }
    }

    @ViewBuilder
    private func cellView(_ cell: LaneCell, width: CGFloat) -> some View {
        switch cell {
        case .slot(let slot):
            EditableCard(slot: slot, lane: lane, arrangement: arrangement, editor: editor)
                .frame(width: width)
                .frame(minHeight: editor.previewing(slot).height)
                .fixedSize(horizontal: false, vertical: true)
        case .gap:
            dropGap(width: width)
        }
    }

    private func dropGap(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(
                Color.dropGapStroke,
                style: StrokeStyle(lineWidth: Stroke.hairline, dash: [Space.one, Space.half])
            )
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Color.dropGapFill)
            )
            .frame(width: width, height: editor.lifted?.size.height ?? WidgetSize.compact.height)
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
        case .widget(let widget, _): widget.view
        case .unavailable(let id): UnavailableWidgetCard(id: id)
        }
    }
}

extension [LaneSlot] {
    /// How wide a lane holding these has to be: the grid its countable spans
    /// make, or the widest uncountable thing in it — whichever is wider. A
    /// lane of cards is the default width; a widened card widens its grid and
    /// an app screen widens its lane to fit rather than cropping, and the
    /// panel grows by that much. An empty lane is a lane of cards until
    /// something says otherwise.
    var width: CGFloat {
        Swift.max(Layout.gridWidth(units: gridUnits), compactMap(\.fixedWidth).max() ?? 0)
    }
}

extension PanelArrangement {
    /// Every lane's width, in order — what edit mode measures the room for one
    /// more column against.
    var laneWidths: [CGFloat] { lanes.map(\.width) }
}

extension LaneSlot {
    /// The slot with its span replaced — what a resize previews and commits,
    /// and what the width guard measures the offer with. An absent widget has
    /// nothing to resize, so its slot comes back unchanged.
    func resized(to span: WidgetSpan) -> LaneSlot {
        switch self {
        case .widget(let widget, _): return .widget(widget, span)
        case .unavailable: return self
        }
    }

    /// The step a resize drag counts in: the widget's own base size, not its
    /// current span, so steps stay the same width wherever the drag starts.
    var resizeStep: CGSize {
        switch self {
        case .widget(let widget, _):
            return CGSize(width: Layout.laneWidth, height: widget.descriptor.size.height)
        case .unavailable:
            return CGSize(width: Layout.laneWidth, height: WidgetSize.compact.height)
        }
    }

    /// A slot standing in for a widget this build doesn't have has no
    /// descriptor to ask, and the smallest card is the least the lane's shape
    /// can be wrong by.
    var height: CGFloat {
        switch self {
        case .widget(let widget, let span):
            let base = widget.descriptor.size.height
            // A resized card asks for multiples of its base height; an app
            // screen keeps its own, which its view already draws.
            return widget.descriptor.size.isResizable ? base * CGFloat(span.height) : base
        case .unavailable: return WidgetSize.compact.height
        }
    }

    /// How wide a lane this slot needs on its own: the lane unit times the
    /// width span, without the shell's inter-column gutters — those belong to
    /// the lane's grid, not the card. A slot standing in for a widget this
    /// build doesn't have takes the default width — the id is all it has, and
    /// nothing in it says the absent widget was ever wider. An app screen
    /// keeps its own width either way.
    var width: CGFloat {
        switch self {
        case .widget(let widget, let span):
            guard widget.descriptor.size.isResizable else { return widget.descriptor.size.width }
            return Layout.laneWidth * CGFloat(span.width)
        case .unavailable: return Layout.laneWidth
        }
    }

    /// What to call this in a label — the widget's own name, or the id, which
    /// is all a slot standing in for an absent widget has.
    var title: String {
        switch self {
        case .widget(let widget, _): widget.descriptor.title
        case .unavailable(let id): id.rawValue
        }
    }
}
