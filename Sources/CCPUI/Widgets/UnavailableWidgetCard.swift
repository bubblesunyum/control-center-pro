// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// Stands in for a widget the layout names and this build doesn't have.
///
/// The position is drawn rather than dropped: the id is still in the file and
/// will resolve again in the build that has it, so a lane that silently came up
/// a card shorter would be describing the arrangement wrongly.
struct UnavailableWidgetCard: View {
    let id: WidgetID

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Space.half) {
                Label("Not in this build", systemImage: "questionmark.square.dashed")
                    .font(.headline)
                    .lineLimit(1)
                Text(id.rawValue)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Color.labelMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Space.oneHalf)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(id.rawValue): not available in this build")
    }
}
