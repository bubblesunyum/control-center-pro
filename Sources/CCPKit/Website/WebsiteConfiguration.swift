// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import WebKit

/// What every website view is built with: one shared process pool and one
/// persistent data store, so cookies and logins survive relaunch and carry
/// across sites and their login popups as first-party state.
///
/// The user agent is pinned to desktop Safari. A 300pt lane is narrower than
/// most responsive breakpoints, so without this some sites sniff the width
/// and serve their phone layout even though the device is a Mac.
@MainActor
public enum WebsiteConfiguration {
    static let processPool = WKProcessPool()

    /// The Safari release the desktop agent claims. One constant: the config
    /// and the view string must never drift apart.
    static let desktopBrowserVersion = "18.4"

    /// Stock desktop Safari. No spoofing beyond what the device already is —
    /// this only stops a narrow card being mistaken for a phone.
    public static var desktopUserAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(desktopBrowserVersion) Safari/605.1.15"
    }

    public static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.applicationNameForUserAgent = "Version/\(desktopBrowserVersion) Safari/605.1.15"
        return config
    }

    /// Pin a live view to the desktop agent. Configurations only set the
    /// default; the view's own string wins, so both pooled views and popups
    /// go through here.
    public static func applyDesktopAgent(to webView: WKWebView) {
        webView.customUserAgent = desktopUserAgent
    }
}
