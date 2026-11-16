// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import WebKit

/// What every website view is built with: one shared process pool and one
/// persistent data store, so cookies and logins survive relaunch and carry
/// across sites and their login popups as first-party state.
///
/// Desktop uses the running Safari's agent, built at launch from the OS
/// itself — never a pinned constant, which is exactly what got us gated by
/// Slack. A narrow card may still get a site's compact layout, but that is
/// the site reading the viewport, not us misreporting the browser. The
/// tablet agent below stays an explicit per-site opt-in.
@MainActor
public enum WebsiteConfiguration {
    static let processPool = WKProcessPool()

    /// The Safari release installed on this Mac, read from Safari.app so the
    /// claimed agent tracks updates. Falls back to a recent release when the
    /// bundle is unreadable; the fallback going stale only costs the same
    /// gate this exists to avoid, so bump it when touching this file.
    static let fallbackSafariVersion = "26.6"

    static var safariVersion: String {
        if let version = Bundle(path: "/Applications/Safari.app")?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            !version.isEmpty
        {
            return version
        }
        return fallbackSafariVersion
    }

    /// The running OS for the tablet agent's CPU token, which requires
    /// underscores — dots would break the claim. Three components when a
    /// patch release is running, matching what a real iPad sends (Apple
    /// omits a zero patch).
    static var tabletOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.patchVersion == 0 {
            return "\(v.majorVersion)_\(v.minorVersion)"
        }
        return "\(v.majorVersion)_\(v.minorVersion)_\(v.patchVersion)"
    }

    /// Full desktop Safari. The `10_15_7` token is WebKit's own compat
    /// fiction, not a version claim — the real claim is `Version/`, which
    /// always names the installed Safari.
    public static var desktopUserAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"
    }

    /// Explicit iPad Safari, for sites whose touch-first layout fits a narrow
    /// card better than their desktop page. Per-site, never global: most of
    /// the web wants the desktop string above.
    public static var tabletUserAgent: String {
        "Mozilla/5.0 (iPad; CPU OS \(tabletOSVersion) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Mobile/15E148 Safari/604.1"
    }

    public static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // The sanctioned half of the claim: WebKit appends this to its bare
        // default agent, so even a view that somehow misses its per-view
        // string still names the running Safari. Same version source as the
        // per-view strings, so the two can never drift apart.
        config.applicationNameForUserAgent = "Version/\(safariVersion) Safari/605.1.15"
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
}
