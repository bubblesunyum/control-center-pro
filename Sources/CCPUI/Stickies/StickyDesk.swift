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
    let store: StickyStore = .shared

    var body: some View {
        ZStack {
            // On the background only: the desk must not eat the lanes'
            // clicks, and a container-level ignore would deaden the cards
            // along with it.
            Color.clear.allowsHitTesting(false)
            ForEach(store.visible) { sticky in
                StickyCard(sticky: sticky, store: store)
                    .position(x: sticky.x, y: sticky.y)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
