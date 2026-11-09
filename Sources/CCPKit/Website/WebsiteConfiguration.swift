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

    /// Stock iPad Safari, for sites whose touch-first layout fits a narrow
    /// card better than their desktop page. Per-site, never global: most of
    /// the web wants the desktop string above.
    public static var tabletUserAgent: String {
        "Mozilla/5.0 (iPad; CPU OS 18_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1"
    }

    public static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.applicationNameForUserAgent = "Version/\(desktopBrowserVersion) Safari/605.1.15"
        return config
    }

    /// Pin a live view to the entry's agent: tablet when the site asks for
    /// it, desktop otherwise. Configurations only set the default; the
    /// view's own string wins, so pooled views and popups go through here.
    public static func applyStoredAgent(for id: WidgetID, to webView: WKWebView) {
        applyAgent(isTablet: WebsiteStore.shared.entry(for: id)?.requestsTabletSite ?? false, to: webView)
    }

    /// Pin a live view to one of the two agents.
    public static func applyAgent(isTablet: Bool, to webView: WKWebView) {
        webView.customUserAgent = isTablet ? tabletUserAgent : desktopUserAgent
    }

    /// Whether the view currently claims the tablet string. The toggle path
    /// applies and reloads live, but a re-mounted view reads this to heal —
    /// an agent change without a reload would never take.
    public static func isTablet(_ webView: WKWebView) -> Bool {
        webView.customUserAgent == tabletUserAgent
    }

    /// Pin a live view to the desktop agent. Configurations only set the
    /// default; the view's own string wins, so both pooled views and popups
    /// go through here.
    public static func applyDesktopAgent(to webView: WKWebView) {
        applyAgent(isTablet: false, to: webView)
    }
}
