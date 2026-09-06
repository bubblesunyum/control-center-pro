// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

/// The documents half of provisioning (ccp-0gek): creating the empty
/// document a pad syncs to. Echo shapes are pinned from the vendor docs and
/// confirmed live (POST `{documents:[{title}]}` → 200
/// `{items:[{id,title,clickableLink}]}`).
final class CraftDocumentsTests: XCTestCase {
    private let base = URL(string: "https://connect.craft.do/links/test/api/v1")!

    private func client(_ transport: ScriptedTransport) -> CraftClient {
        CraftClient(baseURL: base, transport: transport)
    }

    func testCreateParsesItemsEnvelopeWithExtraKeys() async throws {
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
        {"items":[{"id":"new-1","title":"Note 1","clickableLink":"craftdocs://open?spaceId=s&documentId=d"}]}
        """)])
        let created = try await client(transport).createDocument(title: "Note 1")
        XCTAssertEqual(created, CraftDocument(id: "new-1", title: "Note 1"))
        XCTAssertEqual(transport.requests[0].httpMethod, "POST")
        XCTAssertTrue(transport.requests[0].url?.absoluteString.hasSuffix("/documents") ?? false)
        let body = try transport.jsonBody(of: 0)
        XCTAssertEqual((body["documents"] as? [[String: String]])?.first?["title"], "Note 1")
    }

    func testCreateEmptyEchoIsUnreachable() async {
        let transport = ScriptedTransport([.init(statusCode: 200, json: """
        {"items":[]}
        """)])
        do {
            _ = try await client(transport).createDocument(title: "Note 1")
            XCTFail("expected unreachable")
        } catch {
            XCTAssertEqual(error, .unreachable(statusCode: nil))
        }
    }

    func testCreateRateLimited() async {
        let transport = ScriptedTransport([.init(statusCode: 429, json: "{}",
                                                 headers: ["Retry-After": "45"])])
        do {
            _ = try await client(transport).createDocument(title: "Note 1")
            XCTFail("expected rateLimited")
        } catch {
            XCTAssertEqual(error, .rateLimited(retryAfter: 45))
        }
    }
}
