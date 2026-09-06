// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import SwiftUI

/// One sticky note on the panel: a paper card with a drag header over a
/// Markdown editor.
///
/// Fixed size, deliberately — the controller's click-through math needs to
/// know where a sticky is without asking the layout, and a note that changed
/// the panel's shape would be a widget, not a sticky. The header is the only
/// drag handle: a press there moves on the first pixel, and the body stays
/// for typing.
struct StickyCard: View {
    /// What every sticky measures. Centers are stored; `.position` centers,
    /// and the frame helpers below are the one place that math lives — the
    /// desk, the drag guard, and the controller's hit-test all read through
    /// here rather than recomputing.
    static let size = CGSize(width: 240, height: 192)
    static let headerHeight: CGFloat = 28
    /// A new sticky cascades from the one that spawned it, so it never lands
    /// exactly on top of its parent.
    static let cascadeOffset: CGFloat = Space.three
    /// How much of a sticky must stay inside the window to remain grabbable.
    /// Deliberate drifts off-screen are fine; a note with no reachable pixel
    /// is stranded, and the only recovery would be hand-editing the file.
    static let minGrab: CGFloat = 64

    static func frame(center: CGPoint) -> CGRect {
        CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The nearest center whose header strip still intersects the bounds.
    static func clampedCenter(_ center: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(center.x, bounds.minX + minGrab - size.width / 2),
                   bounds.maxX - minGrab + size.width / 2),
            y: min(max(center.y, bounds.minY + size.height / 2 - headerHeight),
                   bounds.maxY + size.height / 2)
        )
    }

    let sticky: Sticky
    let store: StickyStore

    @State private var dragAnchor: CGPoint?
    @GestureState private var isDragActive = false
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.stickyStroke)
                .frame(height: Stroke.hairline)
            MarkdownNoteEditor(
                text: Binding(
                    get: { sticky.text },
                    set: { store.setText($0, for: sticky.id) }
                ),
                documentId: "sticky-\(sticky.id.uuidString)",
                placeholder: "Jot it down…"
            )
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.stickyPaper(for: sticky.color))
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.stickyStroke, lineWidth: Stroke.hairline)
        }
        .shadow(color: .cardShadow, radius: 8, y: 2)
        // Paper is paper in either appearance: the pastel never darkens, so
        // the ink must never lighten — the editor's labelColor would go white
        // in dark mode and wash out.
        .colorScheme(.light)
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
    }

    /// The drag handle. Minimum distance zero so the card is already under
    /// the finger on the first pixel — stickies have no hold-to-edit, unlike
    /// lane cards. The anchor clears when the gesture goes inactive rather
    /// than on end: a cancelled gesture never calls `onEnded`, and a stale
    /// anchor would teleport the next drag.
    private var header: some View {
        HStack(spacing: Space.half) {
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(sticky.displayTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.one)
        .frame(width: Self.size.width, height: Self.headerHeight)
        .contentShape(Rectangle())
        .accessibilityLabel("Move sticky")
        // The cursor is the hover answer: no fill change, just the hand.
        .onHover { hovering in
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
                    if dragAnchor == nil {
                        dragAnchor = CGPoint(x: sticky.x, y: sticky.y)
                    }
                    guard let anchor = dragAnchor else { return }
                    store.move(
                        sticky.id,
                        toX: anchor.x + value.translation.width,
                        toY: anchor.y + value.translation.height
                    )
                }
        )
        .onChange(of: isDragActive) { _, active in
            if !active { dragAnchor = nil }
        }
    }
}
