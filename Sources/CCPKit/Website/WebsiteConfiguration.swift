// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import WebKit

/// What every website view is built with: one shared process pool and one
/// persistent data store, so cookies and logins survive relaunch and carry
/// across sites and their login popups as first-party state.
///
/// Desktop uses the system's default Safari agent — no override — so the
/// claimed version always tracks the running OS instead of going stale and
/// tripping sites with minimum-version gates (Slack did exactly this to a
/// pinned 18.4 string). A narrow card may still get a site's compact layout,
/// but that is the site reading the viewport, not us misreporting the
/// browser. The tablet agent below stays an explicit per-site opt-in.
@MainActor
public enum WebsiteConfiguration {
    static let processPool = WKProcessPool()

    /// Explicit iPad Safari, for sites whose touch-first layout fits a narrow
    /// card better than their desktop page. Per-site, never global: most of
    /// the web wants the system default above.
    public static let tabletUserAgent =
        "Mozilla/5.0 (iPad; CPU OS 26_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1"

    public static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        return config
    }

    /// Pin a live view to the entry's agent: tablet when the site asks for
    /// it, system default otherwise. Configurations only set the default; the
    /// view's own string wins, so pooled views and popups go through here.
    public static func applyStoredAgent(for id: WidgetID, to webView: WKWebView) {
        applyAgent(isTablet: WebsiteStore.shared.entry(for: id)?.requestsTabletSite ?? false, to: webView)
    }

    /// Pin a live view to one of the two agents. Desktop clears the override
    /// so WebKit reports the running Safari; tablet sets the iPad string.
    public static func applyAgent(isTablet: Bool, to webView: WKWebView) {
        webView.customUserAgent = isTablet ? tabletUserAgent : nil
    }

    /// Whether the view currently claims the tablet string. The toggle path
    /// applies and reloads live, but a re-mounted view reads this to heal —
    /// an agent change without a reload would never take.
    public static func isTablet(_ webView: WKWebView) -> Bool {
        webView.customUserAgent == tabletUserAgent
    }
}
