// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import Foundation
import XCTest

final class WebsitePolicyTests: XCTestCase {
    func testIsAllowedAcceptsHttpAndHttps() {
        XCTAssertTrue(WebsitePolicy.isAllowed(URL(string: "http://example.com")))
        XCTAssertTrue(WebsitePolicy.isAllowed(URL(string: "https://example.com/a?b=c")))
        XCTAssertTrue(WebsitePolicy.isAllowed(URL(string: "HTTPS://EXAMPLE.COM")))
    }

    func testIsAllowedRejectsNonWeb() {
        XCTAssertFalse(WebsitePolicy.isAllowed(nil))
        XCTAssertFalse(WebsitePolicy.isAllowed(URL(string: "file:///tmp/a.html")))
        XCTAssertFalse(WebsitePolicy.isAllowed(URL(string: "javascript:alert(1)")))
        XCTAssertFalse(WebsitePolicy.isAllowed(URL(string: "data:text/plain,hi")))
        XCTAssertFalse(WebsitePolicy.isAllowed(URL(string: "about:blank")))
        XCTAssertFalse(WebsitePolicy.isAllowed(URL(string: "mailto:a@example.com")))
        XCTAssertFalse(WebsitePolicy.isAllowed(URL(string: "https:")))
        XCTAssertFalse(WebsitePolicy.isAllowed(URL(string: "https://")))
    }

    func testHostExtraction() {
        XCTAssertEqual(WebsitePolicy.host(of: "https://example.com/a"), "example.com")
        XCTAssertEqual(WebsitePolicy.host(of: "http://sub.example.com/"), "sub.example.com")
        XCTAssertNil(WebsitePolicy.host(of: ""))
        XCTAssertNil(WebsitePolicy.host(of: "not a url"))
        XCTAssertNil(WebsitePolicy.host(of: "mailto:a@example.com"))
    }

    func testVerdictMatrix() {
        XCTAssertEqual(
            WebsitePolicy.verdict(
                url: URL(string: "https://example.com"), targetFrameIsMain: true, isPopup: false),
            .allow)
        XCTAssertEqual(
            WebsitePolicy.verdict(
                url: URL(string: "https://example.com"), targetFrameIsMain: false, isPopup: false),
            .allow)
        XCTAssertEqual(
            WebsitePolicy.verdict(
                url: URL(string: "https://example.com/oauth"), targetFrameIsMain: false,
                isPopup: true),
            .popup)
        XCTAssertEqual(
            WebsitePolicy.verdict(
                url: URL(string: "mailto:a@example.com"), targetFrameIsMain: true, isPopup: false),
            .openExternally)
        XCTAssertEqual(
            WebsitePolicy.verdict(
                url: URL(string: "tel:+15551234567"), targetFrameIsMain: true, isPopup: false),
            .openExternally)
        XCTAssertEqual(
            WebsitePolicy.verdict(
                url: URL(string: "file:///tmp/a.html"), targetFrameIsMain: true, isPopup: false),
            .cancel)
        XCTAssertEqual(
            WebsitePolicy.verdict(url: nil, targetFrameIsMain: true, isPopup: false), .cancel)
        XCTAssertEqual(
            WebsitePolicy.verdict(url: nil, targetFrameIsMain: false, isPopup: true), .cancel)
    }

    func testSubframeNeverOpensExternally() {
        // A hidden iframe must not launch an app with no user gesture.
        XCTAssertEqual(
            WebsitePolicy.verdict(
                url: URL(string: "mailto:a@example.com"), targetFrameIsMain: false, isPopup: false),
            .cancel)
        XCTAssertEqual(
            WebsitePolicy.verdict(
                url: URL(string: "tel:+15551234567"), targetFrameIsMain: false, isPopup: true),
            .cancel)
    }
}
