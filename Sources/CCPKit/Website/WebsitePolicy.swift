// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Single allowlist shared by website sheets, coordinator, and fallback views.
///
/// Adapted from gooey's web-session: one persistent first-party session, so
/// cookies and logins are shared across all sites. Popups carry login (the
/// host sheet must hold a popup until webViewDidClose, the outlivesOpener
/// equivalent), and passkeys are unsupported in embedded views so no bridge
/// is offered here.
public enum WebsitePolicy {
    public enum NavigationVerdict: Equatable, Sendable {
        case allow
        case cancel
        case openExternally
        case popup
    }

    /// Handed to NSWorkspace for out-of-web-view handling.
    private static let externallyOpenable: Set<String> = [
        "mailto", "tel", "sms", "facetime", "callto",
    ]

    public static func isAllowed(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        guard scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }

    public static func host(of raw: String) -> String? {
        guard let host = URL(string: raw)?.host, !host.isEmpty else { return nil }
        return host
    }

    public static func verdict(
        url: URL?,
        targetFrameIsMain: Bool,
        isPopup: Bool
    ) -> NavigationVerdict {
        guard let url, isAllowed(url) else {
            // A hidden subframe navigating somewhere the card can never show
            // must never launch an app: external schemes are a main-frame,
            // user-gesture answer only.
            guard targetFrameIsMain,
                  let scheme = url?.scheme?.lowercased(),
                  externallyOpenable.contains(scheme)
            else {
                return .cancel
            }
            return .openExternally
        }
        if isPopup {
            return .popup
        }
        return .allow
    }
}
