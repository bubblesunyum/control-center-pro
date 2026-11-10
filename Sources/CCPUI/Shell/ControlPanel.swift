// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
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
    private let onLanesFrame: (CGRect) -> Void
    private let onCardFrames: ([CGRect]) -> Void

    @GestureState private var isGestureActive = false
    @State private var headerFrames: [HeaderFrame] = []
    @State private var gripFrames: [GripFrame] = []
    @State private var overflowFrames: [CGRect] = []
    @State private var holdTask: Task<Void, Never>?
    @State private var holdWidgetID: WidgetID?
    /// Where the press that began the resize landed. The resize drag is
    /// measured from here, not from the gesture's panel-space translation:
    /// the lanes grow under the finger, and counting that growth as more drag
    /// feeds the gesture its own output (see `ScreenDragAnchor`).
    @State private var resizeAnchor = ScreenDragAnchor()

    init(arrangement: PanelArrangement, editor: PanelEditor, onLanesFrame: @escaping (CGRect) -> Void = { _ in }, onCardFrames: @escaping ([CGRect]) -> Void = { _ in }) {
        self.arrangement = arrangement
        self.editor = editor
        self.onLanesFrame = onLanesFrame
        self.onCardFrames = onCardFrames
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: Space.oneHalf) {
            lanes
        }
        .padding(Space.oneHalf)
        // The lanes keep their old distance from the corner: the content
        // inset plus the window's old screen inset, now both inside. One
        // visual gutter, not two — everything between the lanes and the
        // screen edge is transparent window.
        .padding([.top, .trailing], Layout.panelInset)
        // The window is cut to the screen, not to the lanes — stickies live
        // anywhere in it — so the panel space is the whole window with the
        // lanes pinned top-right.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .coordinateSpace(.panel)
        .contentShape(Rectangle())
        // The click-catcher: a full-window veil. Clicks on
        // fully-transparent window pixels are never delivered to the app at
        // all — they fall to whatever is below no matter what
        // ignoresMouseEvents says (ccp-ecye) — so the backdrop needs a
        // whisper of alpha to be hittable. The dim reads as depth behind the
        // panel while staying hittable. It has no gesture of its own: the
        // dismissal monitor decides backdrop-vs-content and swallows.
        .background {
            Color.black.opacity(Layout.backdropDimOpacity)
                .ignoresSafeArea()
                .accessibilityHidden(true)
                .mask { backdropFeather }
        }
        // The desktop frost behind everything. Each card already blurs for
        // itself; this is the whole-window backdrop blur underneath the dim.
        // A real behind-window blur — SwiftUI materials only blur what is
        // already inside the window and read as a tint over a transparent
        // panel. AppKit exposes no radius, so this is the system frost at a
        // reduced opacity rather than a heavier full-strength one; it sits
        // behind the dim above, never in front. Both layers feather at the
        // top edge so no hard line crosses the wallpaper under the menu bar.
        .background {
            VisualEffectViewRepresentable(material: .popover)
                .opacity(Layout.backdropBlurOpacity)
                .ignoresSafeArea()
                .accessibilityHidden(true)
                .mask { backdropFeather }
        }
        .environment(\.isPanelEditing, editor.isEditing)
        .environment(\.panelEditor, editor)
        .environment(\.panelArrangement, arrangement)
        .onPreferenceChange(DropZonePreference.self) { zones in
            editor.zones = zones
            reportContentFrames()
        }
        .onPreferenceChange(PanelOverflowFramePreference.self) { bars in
            overflowFrames = bars
            reportContentFrames()
        }
        .onPreferenceChange(HeaderFramePreference.self) { frames in
            headerFrames = frames
        }
        .onPreferenceChange(GripFramePreference.self) { frames in
            gripFrames = frames
        }
        .onPreferenceChange(LanesFramePreference.self) { frame in
            if let frame { onLanesFrame(frame) }
        }
        .overlay(alignment: .topLeading) { cardInTheAir }
        // Above the lanes, below the gallery. Hidden while editing: stickies
        // are always movable, so edit mode has nothing to offer them and
        // they would only cover the wiggle.
        .overlay(alignment: .topLeading) { if !editor.isEditing { StickyDesk(seatWidth: editor.displayWidth) } }
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
                resizeAnchor.reset()
            }
        }
        // A panel nobody can see holds no press: the hold would otherwise
        // fire into a hidden panel and enter edit mode there (ccp-2yy).
        .onPanelHidden {
            holdTask?.cancel()
            holdTask = nil
            holdWidgetID = nil
            resizeAnchor.reset()
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

    /// Every rect the backdrop hit-test counts as the panel's: the cards plus
    /// any floating overflow hung outside them. Each preference handler
    /// refreshes the same union from one fresh value and one settled state —
    /// zones and overflow never change in the same pass (hover never
    /// re-lays-out, layout never flips bar visibility).
    private func reportContentFrames() {
        onCardFrames(editor.zones.map(\.frame) + overflowFrames)
    }

    /// The top edge fades to nothing instead of drawing a line. A mask, not
    /// a second background: it shapes the dim and the frost into the same
    /// soft edge, and the lanes above it are untouched.
    private var backdropFeather: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: Layout.backdropFeatherHeight)
            Color.black
        }
    }

    private var galleryOverlay: some View {
        ZStack {
            // Dim behind the gallery — separate from cardShadow (which is for cards).
            // Screen-wide, deliberately: the window is the screen now, the
            // gallery is modal, and a tap anywhere closes it.
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.snappy) { editor.isShowingGallery = false } }
            GlassCard(isRaised: true) {
                WidgetGallery(arrangement: arrangement) { withAnimation(.snappy) { editor.isShowingGallery = false } }
            }
            .frame(width: Layout.laneWidth)
        }
        // Over the lanes, not the screen's middle: the window is screen-sized
        // now, and a lane-wide card centered on a display reads as lost.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding([.top, .trailing], Space.oneHalf + Layout.panelInset)
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
                // A press starting on a sticky belongs to the sticky's own
                // grab-strip drag — never lift, resize, or arm a hold from it.
                // Read off the store, not a preference: preferences trail by
                // a layout pass, and a press in that gap would arm both the
                // sticky drag and the lane hold at once.
                // The seat width both sides share: `place()` sets it alongside
                // the window frame, so it always equals the drawn width.
                guard !StickyStore.shared.visible.contains(where: {
                    StickyCard.frame(of: $0, inWidth: editor.displayWidth)
                        .contains(value.startLocation)
                }) else { return }
                if editor.isEditing {
                    // A resize in flight steers by translation; a press
                    // starting on a grip begins one. Both return before the
                    // reorder path — answering a resize with a reorder is the
                    // failure these guards exist to prevent. A stale grip
                    // frame with no slot behind it falls through to reorder,
                    // which is what a press on a card means.
                    if editor.resize != nil {
                        editor.updateResize(translation: resizeAnchor.translation())
                        return
                    }
                    // The drag starts from the card as drawn — its zone —
                    // so the first frame is exactly what was grabbed.
                    if let grip = gripFrames.first(where: { $0.frame.contains(value.startLocation) }),
                       let lane = arrangement.layout.position(of: grip.id)?.lane,
                       let zone = editor.zones.first(where: { $0.id == grip.id }),
                       let maxWidth = editor.maxLaneWidth(for: lane, laneWidths: arrangement.laneWidths) {
                        editor.beginResize(grip.id, from: zone.frame.size, maxWidth: maxWidth)
                        resizeAnchor.engage()
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
                resizeAnchor.reset()
                // A resize commits once, on release, at exactly the size the
                // finger left it at. No animation: the card is already drawn
                // at that size, and animating the stored value toward itself
                // would only let the lane flicker through its old one.
                // A click on the grip that never moved stores nothing: an
                // untouched card keeps growing with its content, and a card
                // drawn fitted to a smaller display keeps its real size.
                if let resize = editor.resize {
                    guard resize.size != resize.start else {
                        editor.endResize()
                        return
                    }
                    var settle = Transaction()
                    settle.disablesAnimations = true
                    withTransaction(settle) {
                        commitResize(resize.size, of: resize.id, arrangement: arrangement, editor: editor)
                        editor.endResize()
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
            // A lane that doesn't exist yet, offered where the ghost hovers —
            // leading edge, gutter, or trailing edge. Never in the layout: an
            // empty lane is exactly what `normalized()` closes up. A middle or
            // trailing preview shoves the lanes left of it on screen (the
            // window grows left, pinned right); the leading edge stays put.
            newLaneTarget(at: 0)

            let widths = drawnLaneWidths
            ForEach(arrangement.lanes.indices, id: \.self) { index in
                WidgetLane(
                    lane: index, slots: arrangement.lanes[index], width: widths[index],
                    arrangement: arrangement, editor: editor
                )
                newLaneTarget(at: index + 1)
            }
        }
        // Where the lanes sit in panel space. The window is a full-screen
        // backdrop that swallows clicks outside the panel's own content, so
        // the controller needs this box to know which points are the panel's
        // and which are backdrop.
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LanesFramePreference.self,
                    value: proxy.frame(in: .panel)
                )
            }
        }
    }

    /// Every lane's width as drawn: its widest card — the one under a held
    /// grip at its live size — fitted to the display, so the panel never
    /// runs past either edge.
    private var drawnLaneWidths: [CGFloat] {
        let widths = arrangement.lanes.map { slots in
            slots.map { editor.drawSize(for: $0.id)?.width ?? $0.width }.max() ?? Layout.laneWidth
        }
        return Layout.fittedLaneWidths(widths, inWidth: editor.displayWidth)
    }

    @ViewBuilder
    private func newLaneTarget(at lane: Int) -> some View {
        if editor.offeredNewLaneAt(beside: arrangement.laneWidths) == lane {
            NewLaneTarget()
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
        }
    }

    /// The dragged card, drawn once at the finger rather than in the lane it
    /// came from — the lane keeps its place as a gap that the other cards
    /// close over as the layout reorders beneath it.
    @ViewBuilder private var cardInTheAir: some View {
        if let lifted = editor.lifted, let slot = arrangement.slot(for: lifted.id) {
            let offset = lifted.offset(at: editor.fingerAt)
            LaneSlotCard(slot: slot, isRaised: true)
                // The card reads its own id for header frames and minimized
                // state; the ghost is outside the lane that sets it, so hand
                // it over — otherwise a minimized card lifts as its expanded
                // self clipped to the minimized frame.
                .environment(\.currentWidgetID, lifted.id)
                .frame(width: lifted.size.width, height: lifted.size.height)
                .scaleEffect(PanelEditor.Lifted.scale)
                .offset(x: offset.width, y: offset.height)
                .allowsHitTesting(false)
        }
    }
}

/// One item in a lane: a slot, or the gap where the lifted card would land.
/// Keyed by the slot so a card keeps its identity while the gap moves
/// around it.
@MainActor
private enum LaneCell {
    case slot(LaneSlot)
    case gap

    var key: String {
        switch self {
        case .slot(let slot): "slot-\(slot.id)"
        case .gap: "gap"
        }
    }
}

/// One column of cards, top to bottom, one card to a row.
///
/// The lane is as wide as its widest card and each card is its own width
/// inside it, flush with the lane's trailing edge — the panel is pinned
/// right, so that edge is the one that never moves and the leading corner
/// is free to follow a resize. A lane taller than the display scrolls.
private struct WidgetLane: View {
    let lane: Int
    let slots: [LaneSlot]
    /// How wide the lane draws, already fitted to the display.
    let width: CGFloat
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

    private var cells: [LaneCell] {
        var cells = visibleSlots.map(LaneCell.slot)
        if let gapIndex, editor.lifted != nil {
            cells.insert(.gap, at: min(gapIndex, cells.count))
        }
        return cells
    }

    var body: some View {
        // Always a scroll view, never one swapped in when the lane grows
        // tall: a conditionally remounted scroll view comes back blank, and
        // with it every web view inside. Bounce follows size, so a lane that
        // fits sits still under the wheel.
        ScrollView(.vertical) {
            VStack(alignment: .trailing, spacing: Space.oneHalf) {
                ForEach(cells, id: \.key) { cell in
                    switch cell {
                    case .slot(let slot): card(slot)
                    case .gap: dropGap
                    }
                }
                // The lifted card came from this lane and the finger is not
                // over a valid lane — keep the lane's height stable rather
                // than collapsing it mid-drag.
                if visibleSlots.isEmpty, gapIndex == nil, editor.isDragging,
                   editor.previewLanding == nil, slots.contains(where: { $0.id == editor.lifted?.id }) {
                    Color.clear.frame(width: width, height: editor.lifted?.size.height ?? 0)
                }
            }
            .frame(width: width, alignment: .trailing)
            // Room for what hangs off a card's corners — the remove badge,
            // the grip's overshoot — which the scroll view would otherwise
            // clip. Given back outside, so the lane's footprint is unchanged.
            .padding(Space.half)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: width + Space.one)
        .padding(-Space.half)
        .modifier(RaisedWhileOverflowing())
    }

    /// A card at its own size: the live size under a held grip, the stored
    /// size once resized, the lane's width at natural height otherwise. Never
    /// wider than the lane, which the display may have narrowed.
    private func card(_ slot: LaneSlot) -> some View {
        let size = editor.drawSize(for: slot.id) ?? slot.storedSize
        return EditableCard(
            slot: slot, lane: lane, arrangement: arrangement, editor: editor,
            width: min(size?.width ?? width, width),
            height: size?.height
        )
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
            .frame(
                width: min(editor.lifted?.size.width ?? width, width),
                height: editor.lifted?.size.height ?? WidgetSize.compact.height
            )
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

/// Where a new lane would go. Dashed rather than drawn as glass, because it is
/// a place rather than a thing. Only ever shown targeted — it appears where
/// the ghost already hovers.
private struct NewLaneTarget: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(
                Color.newLaneStrokeTargeted,
                style: StrokeStyle(lineWidth: 2, dash: [Space.one, Space.half])
            )
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Color.newLaneFillTargeted)
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
        case .widget(let widget, _): widget.view
        case .unavailable(let id): UnavailableWidgetCard(id: id)
        }
    }
}
