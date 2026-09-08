// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import SwiftUI

/// One sticky note on the panel: a paper card holding a Markdown editor.
///
/// No visible chrome — no header, no title row. The padded edge is the move
/// handle (hover answers with the open hand) and a resize grip fades into
/// the bottom-right corner after a short hover; everything inside the
/// padding is paper for typing.
///
/// Both gestures steer transient local state per frame and commit to the
/// store once, on release: writing the store per pixel re-renders the desk,
/// re-arms persistence, and re-fires the controller's mouse-through watch on
/// every frame. And both measure themselves in screen points rather than in
/// the gesture's own translation — the card is offset and resized *by* that
/// translation, and SwiftUI converts each event through the card's current
/// transform, so its own motion comes back out of the next frame and the
/// gesture is fed its own output (see `ScreenDragAnchor`). The controller
/// additionally holds its mouse-through verdict for the drag's duration (see
/// `StickyStore.isDragging`): its hit-test reads committed geometry, which
/// trails the finger, and flipping the window through under a held drag
/// starves the gesture.
struct StickyCard: View {
    /// What a never-resized sticky measures: the model's own default, read
    /// through here so the frame helpers below stay the one place the desk,
    /// the drag guard, and the controller's hit-test read geometry from.
    static let defaultSize = CGSize(width: Sticky.defaultWidth, height: Sticky.defaultHeight)
    /// The grabbable padding around every edge. The editor lives inside it,
    /// so this ring is pure grab surface with no text or AppKit tracking
    /// underneath — and what the reclaim math keeps reachable.
    static let edgeWidth: CGFloat = Space.two
    /// A new sticky cascades from the one that spawned it, so it never lands
    /// exactly on top of its parent.
    static let cascadeOffset: CGFloat = Space.three
    /// How much of a sticky must stay inside the window to remain grabbable.
    /// Deliberate drifts off-screen are fine; a note with no reachable pixel
    /// is stranded, and the only recovery would be hand-editing the file.
    static let minGrab: CGFloat = 64
    /// The corner that answers hover and holds the grip: the touch target,
    /// not the drawn mark. Deliberately under the platform's 44pt: the zone
    /// takes a high-priority gesture, and one that size would reach 28pt past
    /// the paper's border and answer a click at the end of the last line with
    /// a resize instead of a caret.
    static let gripZone: CGFloat = Space.three

    static func frame(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func frame(of sticky: Sticky) -> CGRect {
        frame(
            center: CGPoint(x: sticky.x, y: sticky.y),
            size: CGSize(width: sticky.width, height: sticky.height)
        )
    }

    /// The editor's frame inside the chrome: the stored size is the whole
    /// card, padding included, so every geometry reader (desk, drag guard,
    /// controller hit-test, reclaim) shares one definition with the drawing.
    static func editorSize(for size: CGSize) -> CGSize {
        CGSize(
            width: max(size.width - edgeWidth * 2, 0),
            height: max(size.height - edgeWidth * 2, 0)
        )
    }

    /// The nearest center whose rim still intersects the bounds.
    static func clampedCenter(_ center: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(center.x, bounds.minX + minGrab - size.width / 2),
                   bounds.maxX - minGrab + size.width / 2),
            y: min(max(center.y, bounds.minY + size.height / 2 - edgeWidth),
                   bounds.maxY + size.height / 2)
        )
    }

    /// The resize for a drag translation: the size grows by the translation
    /// while the center rides half of it, so the grabbed corner tracks the
    /// finger 1:1 and the opposite corner stands still. Growth is measured
    /// first and the ride derived from what survived the clamp, so the
    /// corner stays glued even at the minimum size.
    static func previewResize(from sticky: Sticky, translation: CGSize) -> (size: CGSize, ride: CGSize) {
        let resized = sticky.resizedTo(
            width: sticky.width + translation.width,
            height: sticky.height + translation.height
        )
        let growth = CGSize(
            width: resized.width - sticky.width,
            height: resized.height - sticky.height
        )
        return (
            CGSize(width: resized.width, height: resized.height),
            CGSize(width: growth.width / 2, height: growth.height / 2)
        )
    }

    let sticky: Sticky
    let store: StickyStore

    @Environment(\.panelFocus) private var panelFocus
    /// The in-flight move, in panel points. Added to the stored position for
    /// drawing and committed once, on release — the card follows the finger
    /// 1:1 while the store hears about it a single time.
    @State private var dragOffset: CGSize = .zero
    /// Where the press that began the move landed, so the drag is measured
    /// against the screen instead of against the card it is moving.
    @State private var moveAnchor = ScreenDragAnchor()
    @GestureState private var isDragActive = false
    /// The in-flight resize: a transient size plus the center's ride, one
    /// clamped commit on release.
    @State private var resizePreview: CGSize?
    @State private var resizeRide: CGSize = .zero
    /// The resize's own anchor — the card grows under the finger, so its
    /// translation is the one most exposed to the feedback.
    @State private var resizeAnchor = ScreenDragAnchor()
    @GestureState private var isResizeActive = false
    @State private var showGrip = false
    /// Whether the pointer is over the move rim. Separate from the cursor it
    /// drives: hover exit fires mid-gesture as the card moves under a held
    /// finger, so popping directly on exit would fight an in-flight drag.
    @State private var isEdgeHovered = false
    @State private var isConfirmingDelete = false

    private var drawnSize: CGSize {
        resizePreview ?? CGSize(width: sticky.width, height: sticky.height)
    }

    /// Everything the finger owes the card this frame: the move's offset
    /// plus the resize's ride.
    private var appliedOffset: CGSize {
        CGSize(
            width: dragOffset.width + resizeRide.width,
            height: dragOffset.height + resizeRide.height
        )
    }

    var body: some View {
        ZStack {
            // The grab surface: a hollow ring behind the editor, exactly the
            // padding. Presses here never reach the text stack — no selection
            // drag, no scroller tracking, no gesture competition — so the
            // move gesture owns them outright.
            GrabRing(inset: Self.edgeWidth)
                .fill(.clear)
                .contentShape(GrabRing(inset: Self.edgeWidth), eoFill: true)
                .accessibilityLabel("Move sticky")
                // The cursor is the hover answer: no fill change, just the hand.
                // Paired strictly — a duplicate enter or a trailing exit after
                // disappear must never push or pop alone.
                .onHover { hovering in
                    if hovering {
                        guard !isEdgeHovered else { return }
                        isEdgeHovered = true
                        NSCursor.openHand.push()
                    } else {
                        guard isEdgeHovered else { return }
                        isEdgeHovered = false
                        NSCursor.pop()
                    }
                }
                .gesture(moveGesture)
            // Fenced off from the drag: a move steers only the card's offset,
            // so the text stack must not re-evaluate per pixel.
            StableStickyEditor(
                text: sticky.text,
                documentId: "sticky-\(sticky.id.uuidString)",
                onText: { store.setText($0, for: sticky.id) },
                // Only the just-created sticky answers: `newSticky()` names it
                // before the card exists, and the claim clears on arrival. Every
                // other sticky stays out of the focus path entirely.
                onCreate: { [weak panelFocus, id = sticky.id] textView in
                    guard panelFocus?.pendingStickyID == id else { return }
                    panelFocus?.pendingStickyID = nil
                    textView.window?.makeFirstResponder(textView)
                }
            )
            .equatable()
            .frame(
                width: Self.editorSize(for: drawnSize).width,
                height: Self.editorSize(for: drawnSize).height
            )
        }
        .frame(width: drawnSize.width, height: drawnSize.height)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.stickyPaper(for: sticky.color))
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.stickyStroke, lineWidth: Stroke.hairline)
        }
        .overlay(alignment: .bottomTrailing) { cornerZone }
        .shadow(color: .cardShadow, radius: 8, y: 2)
        // Paper is paper in either appearance: the pastel never darkens, so
        // the ink must never lighten — the editor's labelColor would go white
        // in dark mode and wash out.
        .colorScheme(.light)
        // The live half of both gestures: the stored position plus this
        // frame's offsets, so the card tracks the finger while the store
        // stays quiet.
        .offset(appliedOffset)
        .accessibilityLabel("Sticky note: \(sticky.displayTitle)")
        .contextMenu {
            Button("Delete", role: .destructive) {
                if sticky.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    store.delete(sticky.id)
                } else {
                    isConfirmingDelete = true
                }
            }
            Button("Archive") { store.archive(sticky.id) }
            Divider()
            Button("New Sticky") {
                store.add(x: sticky.x + Self.cascadeOffset, y: sticky.y + Self.cascadeOffset)
            }
        }
        .confirmationDialog(
            "Delete this sticky?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Sticky", role: .destructive) {
                store.isConfirmingDelete = false
                store.delete(sticky.id)
            }
            Button("Cancel", role: .cancel) {}
        }
        // The panel's Esc handling reads the store flag so the keystroke
        // cancels the dialog instead of hiding the panel from under it.
        .onChange(of: isConfirmingDelete) { _, confirming in
            store.isConfirmingDelete = confirming
        }
        // The store flag follows the gestures, not the pixels: set on lift,
        // cleared on release, so the controller never re-evaluates
        // mouse-through under a held drag. A cancelled gesture never calls
        // `onEnded`: committing here too keeps the travelled distance
        // instead of snapping back.
        .onChange(of: isDragActive) { _, active in
            if active {
                store.isDragging = true
            } else {
                commitDragIfNeeded()
            }
        }
        .onChange(of: isResizeActive) { _, active in
            if active {
                store.isDragging = true
            } else {
                commitResizeIfNeeded()
            }
        }
        // Hiding the panel is a going-away like any other: the window goes
        // down with the graph intact, so this is the only thing that runs.
        .onPanelHidden {
            // The same landing as the release and the system cancel: a hide
            // is not a reason to lose travel, and `orderOut` doesn't end an
            // AppKit tracking session — the finger may still be down, and
            // Esc mid-drag takes this path. Discarding here would snap the
            // note back to where the drag started.
            commitDragIfNeeded()
            commitResizeIfNeeded()
            // The card dies with a confirmed delete while the flag is global:
            // without this the panel stops dismissing (see the Esc path).
            store.isConfirmingDelete = false
            // The pointer never gets an exit from a window that went down
            // under it; without this the open hand outlives the panel
            // (ccp-6cvu).
            if isEdgeHovered {
                NSCursor.pop()
                isEdgeHovered = false
            }
        }
    }

    /// The move drag: steers a transient offset the card draws live and
    /// commits once, on release. Minimum distance zero so the card is
    /// already under the finger on the first pixel — stickies have no
    /// hold-to-edit, unlike lane cards. The handle sits outside the text
    /// stack, so zero never steals a selection. The travel is the anchor's,
    /// not the gesture's: the card is offset by exactly what this hand
    /// returns, so the gesture's own translation would count that back out.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .panel)
            .updating($isDragActive) { _, state, _ in state = true }
            .onChanged { _ in
                dragOffset = moveAnchor.translation()
            }
            .onEnded { _ in
                commitDragIfNeeded()
            }
    }

    /// Commits the travelled offset. Both exits land here — the release and
    /// the system-cancel path, which never calls `onEnded` — so a cancelled
    /// drag keeps the distance it travelled instead of snapping back. Idle
    /// after the first, because the offset is zeroed on the way through.
    private func commitDragIfNeeded() {
        if dragOffset != .zero {
            store.move(
                sticky.id,
                toX: sticky.x + dragOffset.width,
                toY: sticky.y + dragOffset.height
            )
            dragOffset = .zero
        }
        moveAnchor.reset()
        syncDraggingFlag()
    }

    /// The controller's mouse-through verdict follows whether a gesture is
    /// in flight — either gesture — never the per-pixel stream.
    private func syncDraggingFlag() {
        store.isDragging = isDragActive || isResizeActive
    }

    /// The corner's hit area: always installed, so the mark can answer the
    /// pointer at once and the first grab lands whatever the fade is doing.
    /// Only the mark answers `showGrip` — the gesture rides the whole zone
    /// either way, and VoiceOver only sees it while visible. The mark is the
    /// widgets' own corner tick, shared, not a second design, drawn with no
    /// inset so it straddles the paper's edge instead of sitting inside it.
    private var cornerZone: some View {
        ZStack(alignment: .bottomTrailing) {
            CornerTick(inset: 0)
                .stroke(.white, style: StrokeStyle(lineWidth: Stroke.resizeTick, lineCap: .round))
                .shadow(color: .cardShadow, radius: 2, y: 1)
                .opacity(showGrip ? 1 : 0)
        }
        .frame(width: Self.gripZone, height: Self.gripZone)
        .contentShape(Rectangle())
        .accessibilityHidden(!showGrip)
        .accessibilityLabel("Resize sticky")
        .accessibilityValue("\(Int(drawnSize.width)) by \(Int(drawnSize.height))")
        .accessibilityAction(named: "Make wider") { nudgeResize(by: CGSize(width: Space.three, height: 0)) }
        .accessibilityAction(named: "Make narrower") { nudgeResize(by: CGSize(width: -Space.three, height: 0)) }
        .accessibilityAction(named: "Make taller") { nudgeResize(by: CGSize(width: 0, height: Space.three)) }
        .accessibilityAction(named: "Make shorter") { nudgeResize(by: CGSize(width: 0, height: -Space.three)) }
        // Priority over the padding's move gesture where the two overlap:
        // a corner press resizes, never moves.
        .highPriorityGesture(resizeGesture)
        // No delay: the mark answers the corner the moment the pointer is on
        // it. A resize in flight keeps it, since the pointer leaves the zone
        // as the card grows out from under it.
        .onHover { hovering in
            if hovering || !isResizeActive { showGrip = hovering }
        }
        .animation(.easeOut(duration: 0.15), value: showGrip)
    }

    /// The resize drag: steers a clamped preview the card draws live and
    /// commits once, on release. Translation is read in panel space: the
    /// corner travels as the card grows, so a local reading would count the
    /// card's own growth against the finger.
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .panel)
            .updating($isResizeActive) { _, state, _ in state = true }
            .onChanged { _ in
                let travel = resizeAnchor.translation()
                // The first frame is the press itself: a plain corner click
                // must not stand a preview up and write the store on release.
                guard travel != .zero || resizePreview != nil else { return }
                let preview = Self.previewResize(from: sticky, translation: travel)
                resizePreview = preview.size
                resizeRide = preview.ride
            }
            .onEnded { _ in
                commitResizeIfNeeded()
            }
    }

    /// Commits the drawn size, from the release and from the system-cancel
    /// path alike — a cancelled resize keeps what it grew to.
    private func commitResizeIfNeeded() {
        if let preview = resizePreview {
            store.move(sticky.id, toX: sticky.x + resizeRide.width, toY: sticky.y + resizeRide.height)
            store.resize(sticky.id, width: preview.width, height: preview.height)
            resizePreview = nil
            resizeRide = .zero
        }
        resizeAnchor.reset()
        syncDraggingFlag()
    }

    private func nudgeResize(by delta: CGSize) {
        store.resize(
            sticky.id,
            width: sticky.width + delta.width,
            height: sticky.height + delta.height
        )
    }
}

/// The editor, fenced off from drag re-renders: a move steers only the
/// card's offset, so the text view must not hear about every pixel — each
/// body re-evaluation pokes the AppKit stack (header reconcile, scroll and
/// undo bookkeeping) and the dropped frames read as the card trailing the
/// finger. Equal while the text and document match, whatever closures the
/// card rebuilt around them; resizes still land, because the frame sits
/// outside the fence and only the frame moves.
private struct StableStickyEditor: View, Equatable {
    let text: String
    let documentId: String
    let onText: (String) -> Void
    let onCreate: ((NSTextView) -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.documentId == rhs.documentId
    }

    var body: some View {
        MarkdownNoteEditor(
            text: Binding(get: { text }, set: onText),
            documentId: documentId,
            placeholder: "Jot it down…",
            // None of either: the card's 16pt paper border is already the
            // well, and the caret-comfort slack a full-window document wants
            // raises a scroller on a note that visibly fits. The Notes widget
            // keeps both defaults — these presets are sticky-only.
            textInsets: MarkdownNoteEditor.stickyInsets,
            overscroll: MarkdownNoteEditor.stickyOverscroll,
            onCreate: onCreate
        )
    }
}

/// The move handle's shape: the card's rounded rect minus its paper, as one
/// even-odd path — so the padding grabs and the editor types. It sits behind
/// the editor rather than over it: the gesture owns a region AppKit never
/// sees, instead of competing with the text stack for one.
private struct GrabRing: Shape {
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(
            in: rect,
            cornerSize: CGSize(width: Radius.card, height: Radius.card)
        )
        path.addRoundedRect(
            in: rect.insetBy(dx: inset, dy: inset),
            cornerSize: CGSize(
                width: max(Radius.card - inset, 0),
                height: max(Radius.card - inset, 0)
            )
        )
        return path
    }
}
