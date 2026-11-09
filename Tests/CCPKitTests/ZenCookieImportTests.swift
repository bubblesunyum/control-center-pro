// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import WebKit
import XCTest
@testable import CCPKit

/// Zen cookie rows become jar cookies: leading dots stripped, expired rows
/// dropped, session rows kept, empty hosts refused — and the desktop agent
/// stays a Mac.
@MainActor
final class ZenCookieImportTests: XCTestCase {
    private var future: Double { Date().timeIntervalSince1970 + 3600 }

    private func row(
        host: String = ".example.com", name: String = "sid", value: String = "abc",
        path: String? = "/", expiry: Double? = nil, isSecure: Int = 0
    ) -> ZenCookieImport.ZenCookieRow {
        ZenCookieImport.ZenCookieRow(
            host: host, name: name, value: value, path: path,
            expiry: expiry ?? future, isSecure: isSecure
        )
    }

    func testLeadingDotBecomesABareDomain() {
        XCTAssertEqual(row().httpCookie(now: Date().timeIntervalSince1970)?.domain, "example.com")
    }

    func testHostOnlyCookiesKeepTheirHostAndSecure() {
        let cookie = row(host: "example.com", isSecure: 1).httpCookie(now: Date().timeIntervalSince1970)

        XCTAssertEqual(cookie?.domain, "example.com")
        XCTAssertTrue(cookie?.isSecure ?? false)
    }

    func testSessionCookiesImportWithoutAnExpiry() {
        // Firefox marks memory-only logins expiry == 0 — dropping those
        // would miss exactly the sessions the import is for.
        let cookie = row(expiry: 0).httpCookie(now: Date().timeIntervalSince1970)

        XCTAssertNotNil(cookie)
        XCTAssertNil(cookie?.expiresDate)
    }

    func testExpiredAndEmptyRowsAreRefused() {
        let now = Date().timeIntervalSince1970

        XCTAssertNil(row(expiry: now - 10).httpCookie(now: now))
        XCTAssertNil(row(host: "").httpCookie(now: now))
        XCTAssertNil(row(host: ".", name: "x").httpCookie(now: now))
    }

    func testEmptyPathDefaultsToSlash() {
        XCTAssertEqual(row(path: "").httpCookie(now: Date().timeIntervalSince1970)?.path, "/")
        XCTAssertEqual(row(path: nil).httpCookie(now: Date().timeIntervalSince1970)?.path, "/")
    }

    func testRowsDecodeFromSQLiteJSON() throws {
        let json = Data("""
            [{"host":".example.com","name":"sid","value":"abc","path":"/","expiry":9999999999,"isSecure":1}]
            """.utf8)

        let rows = try JSONDecoder().decode([ZenCookieImport.ZenCookieRow].self, from: json)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].host, ".example.com")
        XCTAssertNotNil(rows[0].httpCookie(now: Date().timeIntervalSince1970))
    }

    func testDesktopAgentIsAMacNotAPhone() {
        XCTAssertTrue(WebsiteConfiguration.desktopUserAgent.contains("Macintosh"))
        XCTAssertFalse(WebsiteConfiguration.desktopUserAgent.contains("iPhone"))
    }
}
