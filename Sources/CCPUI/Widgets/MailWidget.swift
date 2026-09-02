// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// psymail, in a lane.
///
/// Control Center Pro carries psymail rather than launching it, and carries all
/// of it: the tab bar and its bundles, the message detail, search and compose
/// are psymail's own views drawn in the panel. So this widget draws no mail of
/// its own — it is the seam that gives psymail's screen a card to live in, and
/// everything inside that card belongs to the other repository.
///
/// That is also why it is a `.screen` widget: the mail app is laid out for its
/// own window, and a lane of 300pt cards is not that.
@MainActor
public final class MailWidget: CCPWidget {
    public static let descriptor = WidgetDescriptor(
        id: "mail",
        title: "Mail",
        symbolName: "tray.full",
        size: .screen
    )

    private let adapter: MailAdapter

    public init() {
        self.adapter = MailAdapter()
    }

    public func makeView() -> some View {
        MailContent(adapter: adapter)
    }

    public func activate() { adapter.activate() }
    public func deactivate() { adapter.deactivate() }
}

// MARK: - Content

/// The card is the frame and nothing else. psymail draws its own header and
/// its own background, so a `WidgetCard`'s title bar and padding would be a
/// second set of both — the glass and the corner are all this has to add.
private struct MailContent: View {
    let adapter: MailAdapter

    var body: some View {
        GlassCard {
            adapter.screen
                // Exactly the declared height, where every other widget treats
                // it as a floor: psymail's screen has no height of its own —
                // it fills what it is given, and a scroll view of mail asked
                // to size itself asks for the whole mailbox. Left to grow it
                // ran off the bottom of the display and took its tab bar,
                // which floats at the foot of the screen, with it.
                .frame(maxWidth: .infinity)
                .frame(height: WidgetSize.screen.height)
        }
        .accessibilityLabel("Mail")
    }
}
