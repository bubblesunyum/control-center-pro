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

    // MARK: - App-private store

    private func appStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "ccp-claude-app-\(UUID().uuidString)")
            .appending(path: "claude-oauth")
    }

    func testAppStorePrefersLiveLoginOverAppCopy() throws {
        let url = appStoreURL()
        let store = AppClaudeCredentialStore(
            fileURL: url,
            legacyFile: InMemoryClaudeCredentialStore(credentials: ClaudeOAuthCredentials(
                accessToken: "legacy")),
            silentLogin: { ClaudeOAuthCredentials(accessToken: "keychain") })
        try store.saveCredentials(ClaudeOAuthCredentials(accessToken: "app-file"))

        // Same unknown expiry on all three: the tie breaks toward the CLI's
        // own login, so a rotation is picked up while the old copy lives.
        XCTAssertEqual(try store.loadCredentials()?.accessToken, "keychain")
        // …and the copy is re-filed, so a build that can't read the
        // keychain (dev re-sign) still serves the healed login.
        let reread = AppClaudeCredentialStore(
            fileURL: url,
            legacyFile: InMemoryClaudeCredentialStore(credentials: nil),
            silentLogin: { nil })
        XCTAssertEqual(try reread.loadCredentials()?.accessToken, "keychain")
    }

    func testAppStoreServesAppFileWhenLoginAbsent() throws {
        let store = AppClaudeCredentialStore(
            fileURL: appStoreURL(),
            legacyFile: InMemoryClaudeCredentialStore(credentials: nil),
            silentLogin: { nil })
        try store.saveCredentials(ClaudeOAuthCredentials(accessToken: "app-file"))

        // Dev builds can't silently read the keychain — the copy is all
        // there is until the next Import.
        XCTAssertEqual(try store.loadCredentials()?.accessToken, "app-file")
    }

    func testAppStoreResyncsWhenAppCopyExpires() throws {
        let url = appStoreURL()
        let store = AppClaudeCredentialStore(
            fileURL: url,
            legacyFile: InMemoryClaudeCredentialStore(credentials: nil),
            silentLogin: { ClaudeOAuthCredentials(
                accessToken: "rotated",
                expiresAt: Date().addingTimeInterval(3600)) })
        try store.saveCredentials(ClaudeOAuthCredentials(
            accessToken: "stale",
            expiresAt: Date().addingTimeInterval(-10)))

        XCTAssertEqual(try store.loadCredentials()?.accessToken, "rotated")
        let reread = AppClaudeCredentialStore(
            fileURL: url,
            legacyFile: InMemoryClaudeCredentialStore(credentials: nil),
            silentLogin: { nil })
        XCTAssertEqual(try reread.loadCredentials()?.accessToken, "rotated")
    }

    func testAppStorePrefersLaterExpiry() throws {
        let store = AppClaudeCredentialStore(
            fileURL: appStoreURL(),
            legacyFile: InMemoryClaudeCredentialStore(credentials: nil),
            silentLogin: { ClaudeOAuthCredentials(
                accessToken: "new",
                expiresAt: Date().addingTimeInterval(7200)) })
        try store.saveCredentials(ClaudeOAuthCredentials(
            accessToken: "old",
            expiresAt: Date().addingTimeInterval(3600)))

        XCTAssertEqual(try store.loadCredentials()?.accessToken, "new")
    }

    func testAppStoreReturnsNilWhenAllExpired() throws {
        let url = appStoreURL()
        let store = AppClaudeCredentialStore(
            fileURL: url,
            legacyFile: InMemoryClaudeCredentialStore(credentials: ClaudeOAuthCredentials(
                accessToken: "legacy-stale",
                expiresAt: Date().addingTimeInterval(-10))),
            silentLogin: { ClaudeOAuthCredentials(
                accessToken: "keychain-stale",
                expiresAt: Date().addingTimeInterval(-10)) })
        try store.saveCredentials(ClaudeOAuthCredentials(
            accessToken: "app-stale",
            expiresAt: Date().addingTimeInterval(-10)))

        XCTAssertNil(try store.loadCredentials())
    }

    func testAppStoreMigratesSilentLoginOnce() throws {
        let url = appStoreURL()
        let store = AppClaudeCredentialStore(
            fileURL: url,
            legacyFile: InMemoryClaudeCredentialStore(credentials: nil),
            silentLogin: { ClaudeOAuthCredentials(accessToken: "migrated") })

        XCTAssertEqual(try store.loadCredentials()?.accessToken, "migrated")
        // Filed, so a later load with no keychain access still serves it.
        let reread = AppClaudeCredentialStore(
            fileURL: url,
            legacyFile: InMemoryClaudeCredentialStore(credentials: nil),
            silentLogin: { nil })
        XCTAssertEqual(try reread.loadCredentials()?.accessToken, "migrated")
    }

    func testAppStoreFallsBackToLegacyFile() throws {
        let url = appStoreURL()
        let store = AppClaudeCredentialStore(
            fileURL: url,
            legacyFile: InMemoryClaudeCredentialStore(credentials: ClaudeOAuthCredentials(
                accessToken: "legacy")),
            silentLogin: { nil })

        XCTAssertEqual(try store.loadCredentials()?.accessToken, "legacy")
        // Read-through only: a legacy login is not copied over.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAppStoreReadsNothingAnywhere() throws {
        let store = AppClaudeCredentialStore(
            fileURL: appStoreURL(),
            legacyFile: InMemoryClaudeCredentialStore(credentials: nil),
            silentLogin: { nil })

        XCTAssertNil(try store.loadCredentials())
    }

    func testAppStoreRoundTripsOwnerOnly() throws {
        let url = appStoreURL()
        let store = AppClaudeCredentialStore(
            fileURL: url,
            legacyFile: InMemoryClaudeCredentialStore(credentials: nil),
            silentLogin: { nil })

        try store.saveCredentials(ClaudeOAuthCredentials(
            accessToken: "app-access", refreshToken: "app-refresh",
            expiresAt: Date().addingTimeInterval(3600)))

        let creds = try store.loadCredentials()
        XCTAssertEqual(creds?.accessToken, "app-access")
        XCTAssertEqual(creds?.refreshToken, "app-refresh")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertEqual(leftovers.count, 1)
    }

    // MARK: - Fallback + 401 retry

    func testFallbackBypassesAppFile() throws {
        let store = AppClaudeCredentialStore(
            fileURL: appStoreURL(),
            legacyFile: InMemoryClaudeCredentialStore(credentials: ClaudeOAuthCredentials(
                accessToken: "legacy")),
            silentLogin: { ClaudeOAuthCredentials(accessToken: "keychain") })
        try store.saveCredentials(ClaudeOAuthCredentials(accessToken: "app-file"))

        XCTAssertEqual(try store.loadFallbackCredentials()?.accessToken, "keychain")
    }

    func testFallbackReadsNothingAnywhere() throws {
        let store = AppClaudeCredentialStore(
            fileURL: appStoreURL(),
            legacyFile: InMemoryClaudeCredentialStore(credentials: nil),
            silentLogin: { nil })

        XCTAssertNil(try store.loadFallbackCredentials())
    }

    func testUnauthorizedRetriesFallbackOnce() async throws {
        ClaudeStubURLProtocol.handler = { request in
            let token = request.value(forHTTPHeaderField: "Authorization")
            if token == "Bearer live-login" {
                return (200, Data(
                    #"{"limits":[{"kind":"session","percent":23.5}]}"#.utf8))
            }
            return (401, Data())
        }
        let credentials = FakeRotatingClaudeCredentialStore(
            primary: ClaudeOAuthCredentials(
                accessToken: "revoked-copy",
                expiresAt: Date().addingTimeInterval(3600)),
            fallback: ClaudeOAuthCredentials(
                accessToken: "live-login",
                expiresAt: Date().addingTimeInterval(3600)))
        let source = LiveClaudeUsageSource(
            credentials: credentials,
            session: ClaudeStubURLProtocol.session)

        let snapshot = try await source.fetch()

        XCTAssertEqual(snapshot.rolling?.percent, 23.5)
        XCTAssertEqual(credentials.fallbackCalls, 1)
        // A verified-live fallback heals the copy for the next load.
        XCTAssertEqual(credentials.saved.last?.accessToken, "live-login")
    }

    func testUnauthorizedWithSameFallbackTokenStaysMissing() async {
        var calls = 0
        ClaudeStubURLProtocol.handler = { _ in
            calls += 1
            return (401, Data())
        }
        let source = LiveClaudeUsageSource(
            credentials: FakeRotatingClaudeCredentialStore(
                primary: ClaudeOAuthCredentials(
                    accessToken: "revoked",
                    expiresAt: Date().addingTimeInterval(3600)),
                fallback: ClaudeOAuthCredentials(
                    accessToken: "revoked",
                    expiresAt: Date().addingTimeInterval(3600))),
            session: ClaudeStubURLProtocol.session)

        do {
            _ = try await source.fetch()
            XCTFail("a revoked token with no alternative must not fetch")
        } catch let error as ClaudeUsageError {
            XCTAssertEqual(error, .missingCredentials)
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(calls, 1)
    }

    func testServerErrorDoesNotTouchFallback() async {
        ClaudeStubURLProtocol.handler = { _ in (500, Data()) }
        let credentials = FakeRotatingClaudeCredentialStore(
            primary: ClaudeOAuthCredentials(
                accessToken: "live",
                expiresAt: Date().addingTimeInterval(3600)),
            fallback: ClaudeOAuthCredentials(
                accessToken: "other",
                expiresAt: Date().addingTimeInterval(3600)))
        let source = LiveClaudeUsageSource(
            credentials: credentials,
            session: ClaudeStubURLProtocol.session)

        do {
            _ = try await source.fetch()
            XCTFail("a 500 must not decode")
        } catch let error as ClaudeUsageError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("wrong error: \(error)")
        }
        // An outage hits every token equally — no point spending the retry.
        XCTAssertEqual(credentials.fallbackCalls, 0)
    }

    // MARK: - Login import

    func testImportCopiesLoginToStore() throws {
        let store = InMemoryClaudeCredentialStore()
        let importer = ClaudeLoginImporter(
            readLogin: { ClaudeOAuthCredentials(accessToken: "imported") },
            store: store)

        XCTAssertTrue(try importer.importLogin())
        XCTAssertEqual(try store.loadCredentials()?.accessToken, "imported")
    }

    func testImportWithoutLoginIsNoop() throws {
        let store = InMemoryClaudeCredentialStore()
        let importer = ClaudeLoginImporter(readLogin: { nil }, store: store)

        XCTAssertFalse(try importer.importLogin())
        XCTAssertNil(try store.loadCredentials())
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

    func testUnauthorizedReadsAsMissingCredentials() async {
        ClaudeStubURLProtocol.handler = { _ in (401, Data()) }
        let source = LiveClaudeUsageSource(
            credentials: InMemoryClaudeCredentialStore(credentials: ClaudeOAuthCredentials(
                accessToken: "revoked",
                expiresAt: Date().addingTimeInterval(3600))),
            session: ClaudeStubURLProtocol.session)

        do {
            _ = try await source.fetch()
            XCTFail("a revoked token must not fetch")
        } catch let error as ClaudeUsageError {
            // Re-import re-syncs; there is no refresh to attempt.
            XCTAssertEqual(error, .missingCredentials)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testExpiredCredentialsSkipNetwork() async {
        var calls = 0
        ClaudeStubURLProtocol.handler = { _ in
            calls += 1
            return (200, Data(#"{"limits":[]}"#.utf8))
        }
        let source = LiveClaudeUsageSource(
            credentials: InMemoryClaudeCredentialStore(credentials: ClaudeOAuthCredentials(
                accessToken: "stale",
                expiresAt: Date().addingTimeInterval(-10))),
            session: ClaudeStubURLProtocol.session)

        do {
            _ = try await source.fetch()
            XCTFail("expired creds must not fetch")
        } catch let error as ClaudeUsageError {
            XCTAssertEqual(error, .missingCredentials)
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(calls, 0)
    }

    func testUnknownExpiryStillTriesNetwork() async throws {
        // Legacy logins predate expiresAt — the endpoint arbitrates those.
        var calls = 0
        ClaudeStubURLProtocol.handler = { _ in
            calls += 1
            return (200, Data(#"{"limits":[]}"#.utf8))
        }
        let source = LiveClaudeUsageSource(
            credentials: InMemoryClaudeCredentialStore(credentials: ClaudeOAuthCredentials(
                accessToken: "legacy")),
            session: ClaudeStubURLProtocol.session)

        _ = try await source.fetch()

        XCTAssertEqual(calls, 1)
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

/// A credential store with a separate fallback login, for the 401-retry
/// path. Same one-actor-at-a-time deal as the other stand-ins.
final class FakeRotatingClaudeCredentialStore: ClaudeCredentialStore, @unchecked Sendable {
    var primary: ClaudeOAuthCredentials?
    var fallback: ClaudeOAuthCredentials?
    private(set) var fallbackCalls = 0
    private(set) var saved: [ClaudeOAuthCredentials] = []

    init(primary: ClaudeOAuthCredentials?, fallback: ClaudeOAuthCredentials?) {
        self.primary = primary
        self.fallback = fallback
    }

    func loadCredentials() throws -> ClaudeOAuthCredentials? { primary }

    func loadFallbackCredentials() throws -> ClaudeOAuthCredentials? {
        fallbackCalls += 1
        return fallback
    }

    func saveCredentials(_ credentials: ClaudeOAuthCredentials) throws {
        saved.append(credentials)
        primary = credentials
    }
}

final class FakeClaudeUsageSource: ClaudeUsageSource {    var nextSnapshot: ClaudeUsageSnapshot
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
