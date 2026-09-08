// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import Foundation

/// A drag measured in screen points from where the press landed, reported in
/// panel space.
///
/// `DragGesture.Value.translation` converts every event through the dragged
/// view's own transform, so a view that moves or grows *from that gesture's
/// output* — an offset card, a card whose frame the drag is sizing — has its
/// own motion subtracted back out of the next frame's translation. The
/// gesture is fed its own output: the card oscillates under the finger and
/// lands somewhere other than where it was dropped, and a two-axis resize
/// reads as if it were locked to a ratio. A screen delta cannot include view
/// motion, by construction.
struct ScreenDragAnchor {
    /// Where the pointer is now, in screen points. A seam, because the whole
    /// value of this type is its lifecycle — anchor once, measure against it,
    /// forget on every exit — and a global read would leave that untestable,
    /// which is how the bug it fixes survived several rounds.
    private let pointer: () -> CGPoint
    private var origin: CGPoint?

    init(pointer: @escaping () -> CGPoint = { NSEvent.mouseLocation }) {
        self.pointer = pointer
    }

    /// Whether a press has been anchored — a gesture is in flight.
    var isEngaged: Bool { origin != nil }

    /// Anchors the press explicitly, for a gesture that recognises the start
    /// somewhere other than its first reported frame.
    mutating func engage() {
        if origin == nil { origin = pointer() }
    }

    /// The panel-space delta since the press. The first call anchors it, so a
    /// `minimumDistance: 0` gesture anchors on mouse-down and its first frame
    /// is honestly zero.
    mutating func translation() -> CGSize {
        let now = pointer()
        guard let origin else {
            origin = now
            return .zero
        }
        // Screen y runs up, panel y runs down.
        return CGSize(width: now.x - origin.x, height: origin.y - now.y)
    }

    /// Forgets the press. Every path out of a gesture must call this —
    /// release, system cancel, and the view leaving the tree — or the next
    /// drag measures from the last one's origin.
    mutating func reset() {
        origin = nil
    }
}
