// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import WebKit
import XCTest
@testable import CCPKit

/// Desktop sends no override so sites see the running Safari; tablet sends
/// the explicit iPad string, per site.
@MainActor
final class WebsiteConfigurationTests: XCTestCase {
    func testDesktopAgentUsesSystemDefault() {
        let webView = WKWebView(frame: .zero, configuration: WebsiteConfiguration.makeConfiguration())
        WebsiteConfiguration.applyAgent(isTablet: false, to: webView)
        // WebKit reports a cleared override as nil or empty depending on
        // version — either way, no custom string is sent.
        XCTAssertTrue(webView.customUserAgent == nil || webView.customUserAgent == "")
        XCTAssertFalse(WebsiteConfiguration.isTablet(webView))
    }

    func testTabletAgentIsAnIPad() {
        let webView = WKWebView(frame: .zero, configuration: WebsiteConfiguration.makeConfiguration())
        WebsiteConfiguration.applyAgent(isTablet: true, to: webView)
        XCTAssertTrue(WebsiteConfiguration.isTablet(webView))
        XCTAssertTrue(WebsiteConfiguration.tabletUserAgent.contains("iPad"))
        XCTAssertFalse(WebsiteConfiguration.tabletUserAgent.contains("Macintosh"))
    }
}
