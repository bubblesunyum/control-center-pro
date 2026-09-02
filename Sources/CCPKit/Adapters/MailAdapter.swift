// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Observation
import PsymailKit
import SwiftUI

/// The mail widget's model: psymail, alive for as long as the app is.
///
/// The other adapters here turn an upstream engine's readings into something a
/// card can draw. This one is a different shape because what it carries is a
/// different thing — psymail is a whole mail app, and the widget shows the app
/// rather than a card of numbers taken from it. So the adapter owns the mail
/// graph and vends the screen; what that screen looks like is psymail's, not
/// ours, and there is nothing here to redraw it with.
///
/// Held across the panel closing, not rebuilt on each open: a reply half
/// written in a thread has to still be there, with the message it was written
/// under, the next time the panel comes up.
@MainActor
@Observable
public final class MailAdapter {
    @ObservationIgnored private let psymail = Psymail()
    @ObservationIgnored private var refresh: Task<Void, Never>?

    public init() {}

    /// The mail screen itself — psymail's own, whole: its header, its tab bar
    /// and bundles, its message detail, search and compose.
    public var screen: some View { PsymailScreen(psymail) }

    // MARK: - Lifecycle

    /// Fetch anything that has gone stale while the panel was down. The screen
    /// refreshes itself the first time it appears; every open after that is a
    /// window being shown again rather than a view appearing, which is a beat
    /// psymail cannot see from where it sits.
    public func activate() {
        refresh?.cancel()
        refresh = Task { [psymail] in await psymail.refreshIfStale() }
    }

    /// Mail that arrives while the panel is down is still on Gmail's server
    /// when it comes back up, and psymail's on-disk cache means the next open
    /// draws instantly from the last fetch — so there is nothing a background
    /// poll would buy that the reopen doesn't.
    public func deactivate() {
        refresh?.cancel()
        refresh = nil
    }
}
