// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import WebKit

/// What every website view is built with: one shared process pool and one
/// persistent data store, so cookies and logins survive relaunch and carry
/// across sites and their login popups as first-party state.
@MainActor
public enum WebsiteConfiguration {
    static let processPool = WKProcessPool()

    public static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        return config
    }
}
