// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import WebKit
import XCTest
@testable import CCPKit

/// Desktop claims the running Safari; tablet claims the explicit iPad
/// string, per site. Both are built from the OS at runtime, never pinned.
@MainActor
final class WebsiteConfigurationTests: XCTestCase {
    func testDesktopAgentIsRunningSafari() {
        XCTAssertTrue(WebsiteConfiguration.desktopUserAgent.contains("Macintosh"))
        XCTAssertFalse(WebsiteConfiguration.desktopUserAgent.contains("iPhone"))
        XCTAssertTrue(
            WebsiteConfiguration.desktopUserAgent.contains("Version/\(WebsiteConfiguration.safariVersion)"),
            "desktop agent was: \(WebsiteConfiguration.desktopUserAgent)"
        )
    }

    func testDesktopViewClaimsRunningSafari() {
        let webView = WKWebView(frame: .zero, configuration: WebsiteConfiguration.makeConfiguration())
        WebsiteConfiguration.applyAgent(isTablet: false, to: webView)
        XCTAssertEqual(webView.customUserAgent, WebsiteConfiguration.desktopUserAgent)
        XCTAssertFalse(WebsiteConfiguration.isTablet(webView))
    }

    func testTabletAgentIsAnIPad() {
        XCTAssertTrue(WebsiteConfiguration.tabletUserAgent.contains("iPad"))
        XCTAssertFalse(WebsiteConfiguration.tabletUserAgent.contains("Macintosh"))
        let webView = WKWebView(frame: .zero, configuration: WebsiteConfiguration.makeConfiguration())
        WebsiteConfiguration.applyAgent(isTablet: true, to: webView)
        XCTAssertTrue(WebsiteConfiguration.isTablet(webView))
    }

    func testTabletCPUOSHasNoDots() {
        let ua = WebsiteConfiguration.tabletUserAgent
        guard let start = ua.range(of: "CPU OS ")?.upperBound,
            let end = ua[start...].range(of: " like")?.lowerBound
        else {
            return XCTFail("tablet agent was: \(ua)")
        }
        XCTAssertFalse(String(ua[start..<end]).contains("."), "tablet agent was: \(ua)")
    }

    func testDesktopNavigatorUserAgent() async throws {
        let webView = WKWebView(frame: .zero, configuration: WebsiteConfiguration.makeConfiguration())
        WebsiteConfiguration.applyAgent(isTablet: false, to: webView)
        let ua = try await webView.evaluateJavaScript("navigator.userAgent") as? String ?? ""
        XCTAssertTrue(ua.contains("Safari"), "desktop navigator.userAgent was: \(ua)")
        XCTAssertTrue(ua.contains("Macintosh"), "desktop navigator.userAgent was: \(ua)")
    }

    func testTabletNavigatorUserAgent() async throws {
        let webView = WKWebView(frame: .zero, configuration: WebsiteConfiguration.makeConfiguration())
        WebsiteConfiguration.applyAgent(isTablet: true, to: webView)
        let ua = try await webView.evaluateJavaScript("navigator.userAgent") as? String ?? ""
        XCTAssertTrue(ua.contains("iPad"), "tablet navigator.userAgent was: \(ua)")
    }
}
