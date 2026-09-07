// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import SwiftUI

/// One sticky note on the panel: a paper card holding a Markdown editor.
///
/// No visible chrome — no header, no title row. The top strip is the move
/// handle (hover answers with the open hand) and a resize grip fades into
/// the bottom-right corner after a one-second hover; everything else is
/// paper for typing.
///
/// Both gestures steer transient local state per frame and commit to the
/// store once, on release. Writing the store per pixel re-renders the desk,
/// re-arms persistence, and re-fires the controller's mouse-through watch on
/// every frame — and the gesture lives on the view those writes recreate,
/// so its anchor re-captures mid-drag and the card shakes instead of
/// following the finger.
struct StickyCard: View {
    /// What a never-resized sticky measures: the model's own default, read
    /// through here so the frame helpers below stay the one place the desk,
    /// the drag guard, and the controller's hit-test read geometry from.
    static let defaultSize = CGSize(width: Sticky.defaultWidth, height: Sticky.defaultHeight)
    /// The invisible move strip across the top. Slim on purpose — the card
    /// is paper now, not a window — but tall enough to grab, and what the
    /// reclaim math keeps reachable.
    static let grabHeight: CGFloat = 16
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
    static let gripHoverDelay: Duration = .seconds(1)
    /// The corner that answers hover and holds the grip: the platform touch
    /// target, not the drawn mark. It sits above the editor, so text in this
    /// one corner answers hover instead of placing the caret — the documented
    /// cost of a hover-to-reveal handle, kept to the corner so the rest of
    /// the paper types untouched.
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

    /// The nearest center whose grab strip still intersects the bounds.
    static func clampedCenter(_ center: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(center.x, bounds.minX + minGrab - size.width / 2),
                   bounds.maxX - minGrab + size.width / 2),
            y: min(max(center.y, bounds.minY + size.height / 2 - grabHeight),
                   bounds.maxY + size.height / 2)
        )
    }

    let sticky: Sticky
    let store: StickyStore

    /// The in-flight move, in panel points. Added to the stored position for
    /// drawing and committed once, on release — the card follows the finger
    /// 1:1 while the store hears about it a single time.
    @State private var dragOffset: CGSize = .zero
    @GestureState private var isDragActive = false
    /// The in-flight resize. Same shape: a transient preview per frame, one
    /// clamped commit on release.
    @State private var resizePreview: CGSize?
    @GestureState private var isResizeActive = false
    @State private var showGrip = false
    @State private var gripTask: Task<Void, Never>?
    /// Whether the pointer is currently over the corner zone / the move
    /// strip. Separate from the actions those drive: hover exit fires
    /// mid-gesture as the card moves under a held finger, so hiding or
    /// cursor-popping directly on exit would kill an in-flight drag.
    @State private var isCornerHovered = false
    @State private var isStripHovered = false
    @State private var isConfirmingDelete = false

    private var drawnSize: CGSize {
        resizePreview ?? CGSize(width: sticky.width, height: sticky.height)
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
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.stickyPaper(for: sticky.color))
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.stickyStroke, lineWidth: Stroke.hairline)
        }
        .overlay(alignment: .top) { grabStrip }
        .overlay(alignment: .bottomTrailing) { cornerZone }
        .shadow(color: .cardShadow, radius: 8, y: 2)
        // Paper is paper in either appearance: the pastel never darkens, so
        // the ink must never lighten — the editor's labelColor would go white
        // in dark mode and wash out.
        .colorScheme(.light)
        // The live half of the move: the stored position plus this drag's
        // offset, so the card tracks the finger while the store stays quiet.
        .offset(dragOffset)
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
            if !active {
                commitResizeIfNeeded()
                // A hover exit that fired mid-drag was deferred while the
                // grip was in flight; honour it now that the gesture is gone.
                if !isCornerHovered { showGrip = false }
            }
        }
        .onDisappear {
            gripTask?.cancel()
            gripTask = nil
            // Dismissing the panel fires no hover exit for a hidden window;
            // without this the open hand outlives the sticky.
            if isStripHovered {
                NSCursor.pop()
                isStripHovered = false
            }
        }
    }

    /// The move handle. Minimum distance zero so the card is already under
    /// the finger on the first pixel — stickies have no hold-to-edit, unlike
    /// lane cards.
    private var grabStrip: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.grabHeight)
            .contentShape(Rectangle())
            .accessibilityLabel("Move sticky")
            // The cursor is the hover answer: no fill change, just the hand.
            .onHover { hovering in
                isStripHovered = hovering
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
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        store.move(
                            sticky.id,
                            toX: sticky.x + value.translation.width,
                            toY: sticky.y + value.translation.height
                        )
                        dragOffset = .zero
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
    }

    /// The corner's hover zone. A full touch target holding a grip that only
    /// exists after the pointer has rested here for a second.
    private var cornerZone: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .frame(width: Self.gripZone, height: Self.gripZone)
                .contentShape(Rectangle())
                .onHover(perform: armGrip)
            if showGrip {
                resizeGrip
            }
        }
        .animation(.easeOut(duration: 0.15), value: showGrip)
    }

    private func armGrip(_ hovering: Bool) {
        isCornerHovered = hovering
        gripTask?.cancel()
        gripTask = nil
        if hovering {
            gripTask = Task { @MainActor in
                try? await Task.sleep(for: Self.gripHoverDelay)
                guard !Task.isCancelled else { return }
                showGrip = true
            }
        } else if !isResizeActive {
            // While a resize is in flight the corner travels with the card
            // and the pointer leaves the zone mid-drag; hiding here would
            // take the gesture's own view with it, so the release path
            // honours the deferred exit instead.
            showGrip = false
        }
    }

    /// The resize handle: the windowing corner tick, a short rounded arc
    /// hugging the card's own corner. The drag steers a clamped preview the
    /// card draws live; the store commits once, on release. Translation is
    /// read in panel space: the corner travels as the card grows, so a local
    /// reading would count the card's own growth against the finger and the
    /// corner would lag the pointer at half speed.
    private var resizeGrip: some View {
        ResizeTick()
            .stroke(.secondary, style: StrokeStyle(lineWidth: Stroke.resizeTick, lineCap: .round))
            .frame(width: Space.two, height: Space.two)
            .padding(Space.one)
            .contentShape(Rectangle())
            .accessibilityLabel("Resize sticky")
            .accessibilityValue("\(Int(drawnSize.width)) by \(Int(drawnSize.height))")
            .accessibilityAction(named: "Make wider") { nudgeResize(by: CGSize(width: Space.three, height: 0)) }
            .accessibilityAction(named: "Make narrower") { nudgeResize(by: CGSize(width: -Space.three, height: 0)) }
            .accessibilityAction(named: "Make taller") { nudgeResize(by: CGSize(width: 0, height: Space.three)) }
            .accessibilityAction(named: "Make shorter") { nudgeResize(by: CGSize(width: 0, height: -Space.three)) }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .panel)
                    .updating($isResizeActive) { _, state, _ in state = true }
                    .onChanged { value in
                        resizePreview = Self.previewSize(from: sticky, translation: value.translation)
                    }
                    .onEnded { value in
                        let size = Self.previewSize(from: sticky, translation: value.translation)
                        store.resize(sticky.id, width: size.width, height: size.height)
                        resizePreview = nil
                    }
            )
    }

    private func commitResizeIfNeeded() {
        guard let preview = resizePreview else { return }
        store.resize(sticky.id, width: preview.width, height: preview.height)
        resizePreview = nil
    }

    private func nudgeResize(by delta: CGSize) {
        store.resize(
            sticky.id,
            width: sticky.width + delta.width,
            height: sticky.height + delta.height
        )
    }

    /// The preview for a resize translation: the model's own rule, read back
    /// as a size the card draws live.
    static func previewSize(from sticky: Sticky, translation: CGSize) -> CGSize {
        let resized = sticky.resizedTo(
            width: sticky.width + translation.width,
            height: sticky.height + translation.height
        )
        return CGSize(width: resized.width, height: resized.height)
    }
}

/// A short arc concentric with the card's own corner: the grip box's outer
/// corner sits exactly on the card's, so centering the arc on it hugs the
/// edge. The lane grip's tick, redrawn small for paper.
private struct ResizeTick: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.maxX, y: rect.maxY),
            radius: min(rect.width, rect.height) - 4,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        return path
    }
}
