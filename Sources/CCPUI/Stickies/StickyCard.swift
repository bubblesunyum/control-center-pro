// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import SwiftUI

/// One sticky note on the panel: a paper card holding a Markdown editor.
///
/// No visible chrome — no header, no title row. Every padded edge is the
/// move handle (hover answers with the open hand) and a resize grip fades
/// into the bottom-right corner after a short hover; everything else is
/// paper for typing.
///
/// Both gestures steer transient local state per frame and commit to the
/// store once, on release. Writing the store per pixel re-renders the desk,
/// re-arms persistence, and re-fires the controller's mouse-through watch on
/// every frame — and the gesture lives on the view those writes recreate,
/// so its anchor re-captures mid-drag and the card shakes instead of
/// following the finger. The controller additionally holds its mouse-through
/// verdict for the drag's duration (see `StickyStore.isDragging`): its
/// hit-test reads committed geometry, which trails the finger, and flipping
/// the window through under a held drag starves the gesture.
struct StickyCard: View {
    /// What a never-resized sticky measures: the model's own default, read
    /// through here so the frame helpers below stay the one place the desk,
    /// the drag guard, and the controller's hit-test read geometry from.
    static let defaultSize = CGSize(width: Sticky.defaultWidth, height: Sticky.defaultHeight)
    /// The grabbable rim around every edge. Invisible, inside the editor's
    /// own text insets so it never covers a glyph — and what the reclaim
    /// math keeps reachable.
    static let edgeWidth: CGFloat = 14
    /// A new sticky cascades from the one that spawned it, so it never lands
    /// exactly on top of its parent.
    static let cascadeOffset: CGFloat = Space.three
    /// How much of a sticky must stay inside the window to remain grabbable.
    /// Deliberate drifts off-screen are fine; a note with no reachable pixel
    /// is stranded, and the only recovery would be hand-editing the file.
    static let minGrab: CGFloat = 64
    /// How long the pointer must rest in the corner before the resize grip
    /// appears. Slow enough to never flash by while reaching for text, fast
    /// enough to find on purpose.
    static let gripHoverDelay: Duration = .milliseconds(500)
    /// The corner that answers hover and holds the grip: the platform touch
    /// target, not the drawn mark.
    static let gripZone: CGFloat = Layout.resizeTouchTarget

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

    /// The in-flight move, in panel points. Added to the stored position for
    /// drawing and committed once, on release — the card follows the finger
    /// 1:1 while the store hears about it a single time.
    @State private var dragOffset: CGSize = .zero
    @GestureState private var isDragActive = false
    /// The in-flight resize: a transient size plus the center's ride, one
    /// clamped commit on release.
    @State private var resizePreview: CGSize?
    @State private var resizeRide: CGSize = .zero
    @GestureState private var isResizeActive = false
    @State private var showGrip = false
    @State private var gripTask: Task<Void, Never>?
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
        MarkdownNoteEditor(
            text: Binding(
                get: { sticky.text },
                set: { store.setText($0, for: sticky.id) }
            ),
            documentId: "sticky-\(sticky.id.uuidString)",
            placeholder: "Jot it down…"
        )
        .frame(width: drawnSize.width, height: drawnSize.height)
        // Where the resize grip lives: hovering is passive — it never eats
        // a click — so the whole card can answer it and the corner needs no
        // hit-testable zone of its own while the grip is hidden.
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): cornerHover(point)
            case .ended: endCornerHover()
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.stickyPaper(for: sticky.color))
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.stickyStroke, lineWidth: Stroke.hairline)
        }
        .overlay { edgeRing }
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
            Button("Delete Sticky", role: .destructive) { store.delete(sticky.id) }
            Button("Cancel", role: .cancel) {}
        }
        // The panel's Esc handling reads the store flag so the keystroke
        // cancels the dialog instead of hiding the panel from under it.
        .onChange(of: isConfirmingDelete) { _, confirming in
            store.isConfirmingDelete = confirming
        }
        // A cancelled gesture never calls `onEnded`: committing here too
        // keeps the travelled distance instead of snapping back.
        .onChange(of: isDragActive) { _, active in
            if !active { commitDragIfNeeded() }
        }
        .onChange(of: isResizeActive) { _, active in
            if !active { commitResizeIfNeeded() }
        }
        .onDisappear {
            gripTask?.cancel()
            gripTask = nil
            // A dead gesture owns nothing: whatever was in flight is over,
            // and the controller must hear that even though no release ran.
            store.isDragging = false
            // Dismissing the panel fires no hover exit for a hidden window;
            // without this the open hand outlives the sticky.
            if isEdgeHovered {
                NSCursor.pop()
                isEdgeHovered = false
            }
        }
    }

    /// The move handle: the padded rim itself, hit-tested hollow so presses
    /// on paper fall through to the editor. Minimum distance zero so the
    /// card is already under the finger on the first pixel — stickies have
    /// no hold-to-edit, unlike lane cards.
    private var edgeRing: some View {
        EdgeRing(edge: Self.edgeWidth)
            .fill(.clear)
            .contentShape(EdgeRing(edge: Self.edgeWidth), eoFill: true)
            .accessibilityLabel("Move sticky")
            // The cursor is the hover answer: no fill change, just the hand.
            .onHover { hovering in
                isEdgeHovered = hovering
                if hovering {
                    NSCursor.openHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .panel)
                    .updating($isDragActive) { _, state, _ in state = true }
                    .onChanged { value in
                        store.isDragging = true
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        store.move(
                            sticky.id,
                            toX: sticky.x + value.translation.width,
                            toY: sticky.y + value.translation.height
                        )
                        dragOffset = .zero
                        store.isDragging = false
                    }
            )
    }

    /// Commits the travelled offset when the gesture ended without `onEnded`
    /// — the system-cancel path. After a normal release the offset is
    /// already zeroed and this is a no-op.
    private func commitDragIfNeeded() {
        guard dragOffset != .zero else { return }
        store.move(
            sticky.id,
            toX: sticky.x + dragOffset.width,
            toY: sticky.y + dragOffset.height
        )
        dragOffset = .zero
        store.isDragging = false
    }

    /// Arms or retires the grip from the card's hover location. Location is
    /// in card space, so the corner rect rides the live size — including
    /// mid-resize, where hiding is deferred to the release path anyway.
    private func cornerHover(_ point: CGPoint) {
        let size = drawnSize
        let inCorner = point.x >= size.width - Self.gripZone
            && point.y >= size.height - Self.gripZone
        if inCorner {
            guard gripTask == nil, !showGrip else { return }
            gripTask = Task { @MainActor in
                try? await Task.sleep(for: Self.gripHoverDelay)
                guard !Task.isCancelled else { return }
                showGrip = true
            }
        } else {
            gripTask?.cancel()
            gripTask = nil
            if !isResizeActive { showGrip = false }
        }
    }

    private func endCornerHover() {
        gripTask?.cancel()
        gripTask = nil
        if !isResizeActive { showGrip = false }
    }

    /// The corner's hit area, present only while the grip shows — so hidden
    /// costs nothing and every visible pixel of it answers the finger. The
    /// gesture rides the whole zone, not the drawn mark.
    @ViewBuilder
    private var cornerZone: some View {
        if showGrip {
            ZStack(alignment: .bottomTrailing) {
                GripMarks()
                    .stroke(.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: Space.two + Space.half, height: Space.two + Space.half)
                    .padding(Space.one)
            }
            .frame(width: Self.gripZone, height: Self.gripZone)
            .contentShape(Rectangle())
            .accessibilityLabel("Resize sticky")
            .accessibilityValue("\(Int(drawnSize.width)) by \(Int(drawnSize.height))")
            .accessibilityAction(named: "Make wider") { nudgeResize(by: CGSize(width: Space.three, height: 0)) }
            .accessibilityAction(named: "Make narrower") { nudgeResize(by: CGSize(width: -Space.three, height: 0)) }
            .accessibilityAction(named: "Make taller") { nudgeResize(by: CGSize(width: 0, height: Space.three)) }
            .accessibilityAction(named: "Make shorter") { nudgeResize(by: CGSize(width: 0, height: -Space.three)) }
            .gesture(resizeGesture)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.15), value: showGrip)
        }
    }

    /// The resize drag: steers a clamped preview the card draws live and
    /// commits once, on release. Translation is read in panel space: the
    /// corner travels as the card grows, so a local reading would count the
    /// card's own growth against the finger.
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .panel)
            .updating($isResizeActive) { _, state, _ in state = true }
            .onChanged { value in
                store.isDragging = true
                let preview = Self.previewResize(from: sticky, translation: value.translation)
                resizePreview = preview.size
                resizeRide = preview.ride
            }
            .onEnded { value in
                let preview = Self.previewResize(from: sticky, translation: value.translation)
                store.move(
                    sticky.id,
                    toX: sticky.x + preview.ride.width,
                    toY: sticky.y + preview.ride.height
                )
                store.resize(sticky.id, width: preview.size.width, height: preview.size.height)
                resizePreview = nil
                resizeRide = .zero
                store.isDragging = false
            }
    }

    private func commitResizeIfNeeded() {
        guard let preview = resizePreview else { return }
        store.move(sticky.id, toX: sticky.x + resizeRide.width, toY: sticky.y + resizeRide.height)
        store.resize(sticky.id, width: preview.width, height: preview.height)
        resizePreview = nil
        resizeRide = .zero
        store.isDragging = false
    }

    private func nudgeResize(by delta: CGSize) {
        store.resize(
            sticky.id,
            width: sticky.width + delta.width,
            height: sticky.height + delta.height
        )
    }
}

/// The move handle's shape: the card's rounded rect minus its paper, as one
/// even-odd path — so the rim grabs and the middle types.
private struct EdgeRing: Shape {
    var edge: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(
            in: rect,
            cornerSize: CGSize(width: Radius.card, height: Radius.card)
        )
        path.addRoundedRect(
            in: rect.insetBy(dx: edge, dy: edge),
            cornerSize: CGSize(
                width: max(Radius.card - edge, 0),
                height: max(Radius.card - edge, 0)
            )
        )
        return path
    }
}

/// Two strokes parallel to the bottom-right diagonal, stacked toward the
/// corner. Explicit endpoints, no angles — an arc's sweep has exactly one
/// wrong way to go and this shape found it.
private struct GripMarks: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 8))
        path.addLine(to: CGPoint(x: rect.maxX - 8, y: rect.minY + 2))
        path.move(to: CGPoint(x: rect.minX + 8, y: rect.maxY - 2))
        path.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.minY + 8))
        return path
    }
}
