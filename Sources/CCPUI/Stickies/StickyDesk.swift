// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// Every visible sticky, floating above the lanes in fixed draw order — array
/// order, new on top, never re-sorted by interaction.
///
/// The desk itself is transparent to clicks: the background ignores
/// hit-testing and each card opts back in, so presses landing between
/// stickies reach the lanes (and presses past those reach whatever the window
/// lets through).
struct StickyDesk: View {
    /// Test seam: the desk reads shared state, but a test seats its own
    /// store — shared state under test is whoever else ran first.
    let store: StickyStore
    /// This render's seat width, from the panel — the same value the drag
    /// guard resolves against, so the guard always matches what is drawn.
    let seatWidth: CGFloat

    init(store: StickyStore = .shared, seatWidth: CGFloat) {
        self.store = store
        self.seatWidth = seatWidth
    }

    var body: some View {
        ZStack {
            // On the background only: the desk must not eat the lanes'
            // clicks, and a container-level ignore would deaden the cards
            // along with it.
            Color.clear.allowsHitTesting(false)
            ForEach(store.visible) { sticky in
                // One definition with the hit-test (see `StickyCard.frame(of:)`):
                // the desk draws where the guard looks.
                let frame = StickyCard.frame(of: sticky, inWidth: seatWidth)
                StickyCard(sticky: sticky, store: store)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Archived and deleted stickies give back their editor and snapshot.
        .onChange(of: store.visible.map(\.id)) { _, ids in
            StickyEditorController.shared.keep(only: Set(ids))
        }
    }
}
