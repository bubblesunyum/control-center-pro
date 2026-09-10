// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
@testable import CCPKit
import XCTest

@MainActor
final class ClaudeUsageAdapterTests: XCTestCase {
    // MARK: - Reporting

    func testPublishesSnapshotFromSource() async {
        let source = FakeClaudeUsageSource(snapshot: ClaudeUsageSnapshot(
            rolling: UsageWindow(percent: 23.5),
            weekly: UsageWindow(percent: 41.2)
        ))
        let adapter = ClaudeUsageAdapter(source: source)

        await adapter.refresh()

        XCTAssertEqual(adapter.snapshot.rolling?.percent, 23.5)
        XCTAssertEqual(adapter.snapshot.weekly?.percent, 41.2)
        XCTAssertNil(adapter.lastError)
        XCTAssertNotNil(adapter.lastUpdated)
    }

    func testFailedFetchKeepsPreviousSnapshotAndSurfacesError() async {
        let source = FakeClaudeUsageSource(error: .unavailable)
        let adapter = ClaudeUsageAdapter(source: source)

        await adapter.refresh()

        XCTAssertEqual(adapter.snapshot, .empty)
        XCTAssertEqual(adapter.lastError, .unavailable)
        XCTAssertNil(adapter.lastUpdated)
    }

    func testMissingCredentialsSurfacesInlineState() async {
        let source = FakeClaudeUsageSource(error: .missingCredentials)
        let adapter = ClaudeUsageAdapter(source: source)

        await adapter.refresh()

        XCTAssertEqual(adapter.lastError, .missingCredentials)
    }

    func testSuccessfulFetchClearsPreviousError() async {
        let source = FakeClaudeUsageSource(error: .unavailable)
        let adapter = ClaudeUsageAdapter(source: source)
        await adapter.refresh()
        XCTAssertEqual(adapter.lastError, .unavailable)

        source.nextError = nil
        source.nextSnapshot = ClaudeUsageSnapshot(
            rolling: UsageWindow(percent: 1))
        await adapter.refresh()

        XCTAssertNil(adapter.lastError)
        XCTAssertEqual(adapter.snapshot.rolling?.percent, 1)
    }

    // MARK: - Caching

    func testActivateFetchesOnceWhileFresh() async {
        let source = FakeClaudeUsageSource(snapshot: ClaudeUsageSnapshot(
            rolling: UsageWindow(percent: 5)))
        let adapter = ClaudeUsageAdapter(source: source)

        adapter.activate()
        _ = await becomesTrue { source.fetchCount >= 1 }
        adapter.activate()

        XCTAssertEqual(source.fetchCount, 1)
        adapter.deactivate()
    }

    func testActivateRefetchesOnceCacheExpires() async {
        let source = FakeClaudeUsageSource(snapshot: ClaudeUsageSnapshot(
            rolling: UsageWindow(percent: 5)))
        let adapter = ClaudeUsageAdapter(source: source, cacheTTL: .milliseconds(20))

        adapter.activate()
        _ = await becomesTrue { source.fetchCount >= 1 }
        try? await Task.sleep(for: .milliseconds(40))
        adapter.activate()
        _ = await becomesTrue { source.fetchCount >= 2 }

        XCTAssertEqual(source.fetchCount, 2)
        adapter.deactivate()
    }

    func testIdleWithPanelShutFetchesNothing() async {
        let source = FakeClaudeUsageSource()
        let adapter = ClaudeUsageAdapter(source: source)
        _ = adapter

        XCTAssertEqual(source.fetchCount, 0)
        XCTAssertFalse(adapter.isFetching)
    }

    // MARK: - Limits decoding

    func testDecodesSessionAndWeeklyAll() throws {
        let json = """
            {"limits":[
                {"kind":"session","percent":23.5,"resets_at":"2026-09-10T22:00:00+00:00"},
                {"kind":"weekly_all","percent":41.2,"resets_at":"2026-09-17T00:00:00Z"}]}
            """

        let snapshot = try LiveClaudeUsageSource.decodeSnapshot(from: Data(json.utf8))

        XCTAssertEqual(snapshot.rolling?.percent, 23.5)
        XCTAssertNotNil(snapshot.rolling?.resetsAt)
        XCTAssertEqual(snapshot.weekly?.percent, 41.2)
        XCTAssertNotNil(snapshot.weekly?.resetsAt)
    }

    func testIgnoresScopedAndUnknownKinds() throws {
        let json = """
            {"limits":[
                {"kind":"session","percent":10},
                {"kind":"weekly_scoped","percent":39,"scope":{"model":{"display_name":"Sonnet"}}},
                {"kind":"weekly_scoped","percent":12,"scope":{"model":{"display_name":"Opus"}}},
                {"kind":"something_new","percent":50}]}
            """

        let snapshot = try LiveClaudeUsageSource.decodeSnapshot(from: Data(json.utf8))

        XCTAssertEqual(snapshot.rolling?.percent, 10)
        // Scoped weeklies are deliberately not shown; the user chose 5h + weekly-all.
        XCTAssertNil(snapshot.weekly)
    }

    func testSkipsInvalidEntriesButKeepsTheRest() throws {
        let json = """
            {"limits":[
                {"kind":"session","percent":150},
                {"kind":"weekly_all","percent":41.2}]}
            """

        let snapshot = try LiveClaudeUsageSource.decodeSnapshot(from: Data(json.utf8))

        XCTAssertNil(snapshot.rolling)
        XCTAssertEqual(snapshot.weekly?.percent, 41.2)
    }

    func testSkipsNonObjectEntries() throws {
        let json = """
            {"limits":[
                null,
                "session",
                {"kind":"session","percent":10}]}
            """

        let snapshot = try LiveClaudeUsageSource.decodeSnapshot(from: Data(json.utf8))

        XCTAssertEqual(snapshot.rolling?.percent, 10)
    }

    func testRejectsMissingLimits() {
        XCTAssertThrowsError(
            try LiveClaudeUsageSource.decodeSnapshot(from: Data(#"{"five_hour":null}"#.utf8)))
        XCTAssertThrowsError(
            try LiveClaudeUsageSource.decodeSnapshot(from: Data("nope".utf8)))
    }

    // MARK: - Credential store

    func testFileStoreReturnsNilWhenAbsent() throws {
        let store = FileClaudeCredentialStore(
            credentialsFile: URL(fileURLWithPath: "/nonexistent/.credentials.json"))

        XCTAssertNil(try store.loadCredentials())
    }

    func testFileStoreReadsOAuthShape() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "ccp-claude-\(UUID().uuidString).json")
        let json = """
            {"claudeAiOauth":{
                "accessToken":"sk-ant-oat-live",
                "refreshToken":"sk-ant-oar-live",
                "expiresAt":1787592663293,
                "subscriptionType":"max_5x"}}
            """
        try Data(json.utf8).write(to: file)
        let store = FileClaudeCredentialStore(credentialsFile: file)

        let creds = try store.loadCredentials()

        XCTAssertEqual(creds?.accessToken, "sk-ant-oat-live")
        XCTAssertEqual(creds?.refreshToken, "sk-ant-oar-live")
        XCTAssertEqual(
            creds?.expiresAt,
            Date(timeIntervalSince1970: 1787592663.293))
    }

    func testFileStoreRoundTripsAndKeepsOtherKeys() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "ccp-claude-\(UUID().uuidString).json")
        try Data(#"{"claudeAiOauth":{"subscriptionType":"max_5x"}}"#.utf8).write(to: file)
        let store = FileClaudeCredentialStore(credentialsFile: file)

        try store.saveCredentials(ClaudeOAuthCredentials(
            accessToken: "new-access", refreshToken: "new-refresh",
            expiresAt: Date(timeIntervalSince1970: 2_000_000)))

        let creds = try store.loadCredentials()
        XCTAssertEqual(creds?.accessToken, "new-access")
        XCTAssertEqual(creds?.refreshToken, "new-refresh")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual(
            (raw?["claudeAiOauth"] as? [String: Any])?["subscriptionType"] as? String,
            "max_5x")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        // A failed write must not leave token-bearing tmps behind.
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    // MARK: - Live source HTTP mapping

    func testLiveFetchDecodesHappyPath() async throws {
        var beta: String?
        var path: String?
        ClaudeStubURLProtocol.handler = { request in
            beta = request.value(forHTTPHeaderField: "anthropic-beta")
            path = request.url?.path
            return (200, Data(
                #"{"limits":[{"kind":"session","percent":23.5}]}"#.utf8))
        }
        let source = LiveClaudeUsageSource(
            credentials: InMemoryClaudeCredentialStore(credentials: ClaudeOAuthCredentials(
                accessToken: "live", expiresAt: Date().addingTimeInterval(3600))),
            session: ClaudeStubURLProtocol.session)

        let snapshot = try await source.fetch()

        XCTAssertEqual(snapshot.rolling?.percent, 23.5)
        XCTAssertEqual(path, "/api/oauth/usage")
        XCTAssertEqual(beta, "oauth-2025-04-20")
    }

    func testMissingFileReadsAsMissingCredentials() async {
        let source = LiveClaudeUsageSource(
            credentials: InMemoryClaudeCredentialStore(credentials: nil),
            session: ClaudeStubURLProtocol.session)

        do {
            _ = try await source.fetch()
            XCTFail("no credentials must not fetch")
        } catch let error as ClaudeUsageError {
            XCTAssertEqual(error, .missingCredentials)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testExpiredTokenRefreshesProactively() async throws {
        var usageAuth: String?
        ClaudeStubURLProtocol.handler = { request in
            if request.url?.absoluteString.contains("/oauth/token") == true {
                return (200, Data(
                    #"{"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_in":3600}"#.utf8))
            }
            usageAuth = request.value(forHTTPHeaderField: "Authorization")
            return (200, Data(#"{"limits":[]}"#.utf8))
        }
        let store = InMemoryClaudeCredentialStore(credentials: ClaudeOAuthCredentials(
            accessToken: "stale", refreshToken: "refresh-me",
            expiresAt: Date().addingTimeInterval(-10)))
        let source = LiveClaudeUsageSource(credentials: store, session: ClaudeStubURLProtocol.session)

        _ = try await source.fetch()

        XCTAssertEqual(usageAuth, "Bearer fresh-access")
        // The rotated refresh token is persisted, or the next refresh logs the user out.
        XCTAssertEqual(try store.loadCredentials()?.refreshToken, "fresh-refresh")
    }

    func testRejectedTokenRefreshesOnceAndRetries() async throws {
        var usageCalls = 0
        var retryAuth: String?
        ClaudeStubURLProtocol.handler = { request in
            if request.url?.absoluteString.contains("/oauth/token") == true {
                return (200, Data(#"{"access_token":"second-wind","expires_in":3600}"#.utf8))
            }
            usageCalls += 1
            if usageCalls == 1 {
                return (401, Data())
            }
            retryAuth = request.value(forHTTPHeaderField: "Authorization")
            return (200, Data(#"{"limits":[{"kind":"session","percent":7}]}"#.utf8))
        }
        let source = LiveClaudeUsageSource(
            credentials: InMemoryClaudeCredentialStore(credentials: ClaudeOAuthCredentials(
                accessToken: "dead", refreshToken: "refresh-me",
                expiresAt: Date().addingTimeInterval(3600))),
            session: ClaudeStubURLProtocol.session)

        let snapshot = try await source.fetch()

        XCTAssertEqual(snapshot.rolling?.percent, 7)
        XCTAssertEqual(usageCalls, 2)
        XCTAssertEqual(retryAuth, "Bearer second-wind")
    }

    func testRetryRejectedTwiceReadsAsMissingCredentials() async {
        ClaudeStubURLProtocol.handler = { request in
            if request.url?.absoluteString.contains("/oauth/token") == true {
                return (200, Data(#"{"access_token":"no-good-either","expires_in":3600}"#.utf8))
            }
            return (401, Data())
        }
        let source = LiveClaudeUsageSource(
            credentials: InMemoryClaudeCredentialStore(credentials: ClaudeOAuthCredentials(
                accessToken: "dead", refreshToken: "refresh-me",
                expiresAt: Date().addingTimeInterval(3600))),
            session: ClaudeStubURLProtocol.session)

        do {
            _ = try await source.fetch()
            XCTFail("a twice-rejected token must not fetch")
        } catch let error as ClaudeUsageError {
            // The grant is gone — only a fresh login fixes it, not waiting.
            XCTAssertEqual(error, .missingCredentials)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testRefreshBlipFallsBackToLoadedToken() async throws {
        var usageCalls = 0
        ClaudeStubURLProtocol.handler = { request in
            if request.url?.absoluteString.contains("/oauth/token") == true {
                return (500, Data())
            }
            usageCalls += 1
            return (200, Data(#"{"limits":[{"kind":"session","percent":11}]}"#.utf8))
        }
        let source = LiveClaudeUsageSource(
            credentials: InMemoryClaudeCredentialStore(credentials: ClaudeOAuthCredentials(
                accessToken: "still-good", refreshToken: "refresh-me",
                expiresAt: Date().addingTimeInterval(-10))),
            session: ClaudeStubURLProtocol.session)

        let snapshot = try await source.fetch()

        XCTAssertEqual(snapshot.rolling?.percent, 11)
        XCTAssertEqual(usageCalls, 1)
    }

    func testProactiveRefreshPrefersRotatedFile() async throws {
        var tokenCalls = 0
        var usageAuth: String?
        ClaudeStubURLProtocol.handler = { request in
            if request.url?.absoluteString.contains("/oauth/token") == true {
                tokenCalls += 1
                return (200, Data(#"{"access_token":"should-not-happen","expires_in":3600}"#.utf8))
            }
            usageAuth = request.value(forHTTPHeaderField: "Authorization")
            return (200, Data(#"{"limits":[]}"#.utf8))
        }
        // First load is stale-expired; anything after is what Claude Code
        // rotated in while this fetch was starting.
        let store = ScriptedClaudeCredentialStore(credentials: [
            ClaudeOAuthCredentials(
                accessToken: "stale", refreshToken: "consumed-elsewhere",
                expiresAt: Date().addingTimeInterval(-10)),
            ClaudeOAuthCredentials(
                accessToken: "rotated", refreshToken: "fresh",
                expiresAt: Date().addingTimeInterval(3600)),
        ])
        let source = LiveClaudeUsageSource(credentials: store, session: ClaudeStubURLProtocol.session)

        _ = try await source.fetch()

        XCTAssertEqual(usageAuth, "Bearer rotated")
        XCTAssertEqual(tokenCalls, 0)
    }

    func testDeadRefreshTokenReadsAsMissingCredentials() async {
        ClaudeStubURLProtocol.handler = { request in
            if request.url?.absoluteString.contains("/oauth/token") == true {
                return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            return (401, Data())
        }
        let source = LiveClaudeUsageSource(
            credentials: InMemoryClaudeCredentialStore(credentials: ClaudeOAuthCredentials(
                accessToken: "dead", refreshToken: "also-dead",
                expiresAt: Date().addingTimeInterval(3600))),
            session: ClaudeStubURLProtocol.session)

        do {
            _ = try await source.fetch()
            XCTFail("a dead refresh must not fetch")
        } catch let error as ClaudeUsageError {
            XCTAssertEqual(error, .missingCredentials)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testServerErrorReadsAsUnavailable() async {
        ClaudeStubURLProtocol.handler = { _ in (500, Data()) }
        let source = LiveClaudeUsageSource(
            credentials: InMemoryClaudeCredentialStore(credentials: ClaudeOAuthCredentials(
                accessToken: "live", expiresAt: Date().addingTimeInterval(3600))),
            session: ClaudeStubURLProtocol.session)

        do {
            _ = try await source.fetch()
            XCTFail("a 500 must not decode")
        } catch let error as ClaudeUsageError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testProxy403ReadsAsUnavailable() async {
        ClaudeStubURLProtocol.handler = { _ in (403, Data("<html>blocked</html>".utf8)) }
        let source = LiveClaudeUsageSource(
            credentials: InMemoryClaudeCredentialStore(credentials: ClaudeOAuthCredentials(
                accessToken: "live", expiresAt: Date().addingTimeInterval(3600))),
            session: ClaudeStubURLProtocol.session)

        do {
            _ = try await source.fetch()
            XCTFail("a proxy 403 must not decode")
        } catch let error as ClaudeUsageError {
            // Not a login problem — re-authenticating would loop to no effect.
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
    func testOrgDisabledOAuthReadsAsUnavailable() async {
        ClaudeStubURLProtocol.handler = { _ in
            (403, Data(
                #"{"error":{"message":"OAuth is disabled","details":{"error_code":"oauth_not_allowed_for_organization"}}}"#.utf8))
        }
        let source = LiveClaudeUsageSource(
            credentials: InMemoryClaudeCredentialStore(credentials: ClaudeOAuthCredentials(
                accessToken: "live", expiresAt: Date().addingTimeInterval(3600))),
            session: ClaudeStubURLProtocol.session)

        do {
            _ = try await source.fetch()
            XCTFail("org-disabled OAuth must not decode")
        } catch let error as ClaudeUsageError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    override func tearDown() {
        ClaudeStubURLProtocol.handler = nil
        super.tearDown()
    }
}

// MARK: - Fakes

/// Routes each request through `handler`, so the usage and token endpoints
/// can answer differently within one fetch.
final class ClaudeStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClaudeStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class FakeClaudeUsageSource: ClaudeUsageSource {
    var nextSnapshot: ClaudeUsageSnapshot
    var nextError: ClaudeUsageError?
    private(set) var fetchCount = 0

    init(snapshot: ClaudeUsageSnapshot = .empty, error: ClaudeUsageError? = nil) {
        self.nextSnapshot = snapshot
        self.nextError = error
    }

    func fetch() async throws -> ClaudeUsageSnapshot {
        fetchCount += 1
        if let nextError { throw nextError }
        return nextSnapshot
    }
}

/// Replays a script of credentials, one per load: stands in for Claude Code
/// rotating the file mid-fetch.
final class ScriptedClaudeCredentialStore: ClaudeCredentialStore {
    private var remaining: [ClaudeOAuthCredentials?]
    private var saved: ClaudeOAuthCredentials?

    init(credentials: [ClaudeOAuthCredentials?]) {
        self.remaining = credentials
    }

    func loadCredentials() throws -> ClaudeOAuthCredentials? {
        if remaining.count > 1 { return remaining.removeFirst() }
        return remaining.first ?? saved
    }

    func saveCredentials(_ credentials: ClaudeOAuthCredentials) throws {
        saved = credentials
    }
}
