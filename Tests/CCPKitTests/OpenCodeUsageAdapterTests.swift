// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import XCTest

@MainActor
final class OpenCodeUsageAdapterTests: XCTestCase {
    // MARK: - Reporting

    func testPublishesSnapshotFromSource() async {
        let source = FakeOpenCodeUsageSource(snapshot: OpenCodeUsageSnapshot(
            rolling: OpenCodeUsageWindow(percent: 12.5),
            weekly: OpenCodeUsageWindow(percent: 30),
            monthly: OpenCodeUsageWindow(percent: 45)
        ))
        let adapter = OpenCodeUsageAdapter(source: source)

        await adapter.refresh()

        XCTAssertEqual(adapter.snapshot.rolling?.percent, 12.5)
        XCTAssertEqual(adapter.snapshot.weekly?.percent, 30)
        XCTAssertEqual(adapter.snapshot.monthly?.percent, 45)
        XCTAssertNil(adapter.lastError)
        XCTAssertNotNil(adapter.lastUpdated)
    }

    func testFailedFetchKeepsPreviousSnapshotAndSurfacesError() async {
        let source = FakeOpenCodeUsageSource(error: .unavailable)
        let adapter = OpenCodeUsageAdapter(source: source)

        await adapter.refresh()

        XCTAssertEqual(adapter.snapshot, .empty)
        XCTAssertEqual(adapter.lastError, .unavailable)
        XCTAssertNil(adapter.lastUpdated)
    }

    func testMissingCredentialsSurfacesInlineState() async {
        let source = FakeOpenCodeUsageSource(error: .missingCredentials)
        let adapter = OpenCodeUsageAdapter(source: source)

        await adapter.refresh()

        XCTAssertEqual(adapter.lastError, .missingCredentials)
    }

    func testSuccessfulFetchClearsPreviousError() async {
        let source = FakeOpenCodeUsageSource(error: .unavailable)
        let adapter = OpenCodeUsageAdapter(source: source)
        await adapter.refresh()
        XCTAssertEqual(adapter.lastError, .unavailable)

        source.nextError = nil
        source.nextSnapshot = OpenCodeUsageSnapshot(
            rolling: OpenCodeUsageWindow(percent: 1))
        await adapter.refresh()

        XCTAssertNil(adapter.lastError)
        XCTAssertEqual(adapter.snapshot.rolling?.percent, 1)
    }

    // MARK: - Caching

    func testActivateFetchesOnceWhileFresh() async {
        let source = FakeOpenCodeUsageSource(snapshot: OpenCodeUsageSnapshot(
            rolling: OpenCodeUsageWindow(percent: 5)))
        let adapter = OpenCodeUsageAdapter(source: source)

        adapter.activate()
        _ = await becomesTrue { source.fetchCount >= 1 }
        adapter.activate()

        XCTAssertEqual(source.fetchCount, 1)
        adapter.deactivate()
    }

    func testActivateRefetchesOnceCacheExpires() async {
        let source = FakeOpenCodeUsageSource(snapshot: OpenCodeUsageSnapshot(
            rolling: OpenCodeUsageWindow(percent: 5)))
        let adapter = OpenCodeUsageAdapter(source: source, cacheTTL: .milliseconds(20))

        adapter.activate()
        _ = await becomesTrue { source.fetchCount >= 1 }
        try? await Task.sleep(for: .milliseconds(40))
        adapter.activate()
        _ = await becomesTrue { source.fetchCount >= 2 }

        XCTAssertEqual(source.fetchCount, 2)
        adapter.deactivate()
    }

    func testIdleWithPanelShutFetchesNothing() async {
        let source = FakeOpenCodeUsageSource()
        let adapter = OpenCodeUsageAdapter(source: source)
        _ = adapter

        XCTAssertEqual(source.fetchCount, 0)
        XCTAssertFalse(adapter.isFetching)
    }

    // MARK: - Payload decoding

    func testDecodesLivePayloadShape() throws {
        let json = """
            {"usage":{
                "rolling":{"status":"ok","percent":2,"resetsAt":"2026-09-05T20:33:16.691Z"},
                "weekly":{"status":"ok","percent":4,"resetsAt":"2026-09-07T00:00:00.691Z"},
                "monthly":{"status":"ok","percent":2,"resetsAt":"2026-10-05T00:46:03.691Z"}}}
            """

        let snapshot = try LiveOpenCodeUsageSource.decodeSnapshot(from: Data(json.utf8))

        XCTAssertEqual(snapshot.rolling?.percent, 2)
        XCTAssertEqual(snapshot.rolling?.isRateLimited, false)
        XCTAssertNotNil(snapshot.rolling?.resetsAt)
        XCTAssertEqual(snapshot.weekly?.percent, 4)
        XCTAssertEqual(snapshot.monthly?.percent, 2)
    }

    func testDecodesFloatPercentAndDatelessReset() throws {
        let json = """
            {"usage":{"rolling":{"status":"ok","percent":12.5},"weekly":{"status":"ok","percent":30}}}
            """

        let snapshot = try LiveOpenCodeUsageSource.decodeSnapshot(from: Data(json.utf8))

        XCTAssertEqual(snapshot.rolling?.percent, 12.5)
        XCTAssertNil(snapshot.rolling?.resetsAt)
        XCTAssertNil(snapshot.monthly)
    }

    func testMarksRateLimitedWindows() throws {
        let json = """
            {"usage":{"rolling":{"status":"rate-limited","percent":100,"resetsAt":"2026-09-05T20:33:16Z"}}}
            """

        let snapshot = try LiveOpenCodeUsageSource.decodeSnapshot(from: Data(json.utf8))

        XCTAssertEqual(snapshot.rolling?.isRateLimited, true)
    }

    func testRejectsGarbagePayload() {
        XCTAssertThrowsError(
            try LiveOpenCodeUsageSource.decodeSnapshot(from: Data("nope".utf8)))
    }

    // MARK: - Credential store

    func testFileStoreReturnsNilWhenAbsent() throws {
        let store = FileOpenCodeCredentialStore(
            authFile: URL(fileURLWithPath: "/nonexistent/auth.json"))

        XCTAssertNil(try store.loadAPIKey())
    }

    // MARK: - Live source HTTP mapping

    func testExpiredKeyReadsAsMissingCredentials() async {
        StubURLProtocol.statusCode = 401
        StubURLProtocol.body = Data(#"{"error":"unauthorized"}"#.utf8)
        let source = LiveOpenCodeUsageSource(
            credentials: InMemoryOpenCodeCredentialStore(key: "stale"),
            session: StubURLProtocol.session)

        do {
            _ = try await source.fetch()
            XCTFail("a 401 must not decode")
        } catch let error as OpenCodeUsageError {
            XCTAssertEqual(error, .missingCredentials)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testServerErrorReadsAsUnavailable() async {
        StubURLProtocol.statusCode = 500
        StubURLProtocol.body = Data()
        let source = LiveOpenCodeUsageSource(
            credentials: InMemoryOpenCodeCredentialStore(key: "valid"),
            session: StubURLProtocol.session)

        do {
            _ = try await source.fetch()
            XCTFail("a 500 must not decode")
        } catch let error as OpenCodeUsageError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testLiveFetchDecodesHappyPath() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.body = Data(
            #"{"usage":{"rolling":{"status":"ok","percent":2,"resetsAt":"2026-09-05T20:33:16.691Z"}}}"#.utf8)
        let source = LiveOpenCodeUsageSource(
            credentials: InMemoryOpenCodeCredentialStore(key: "valid"),
            session: StubURLProtocol.session)

        let snapshot = try await source.fetch()

        XCTAssertEqual(snapshot.rolling?.percent, 2)
        XCTAssertNotNil(snapshot.rolling?.resetsAt)
    }
}

// MARK: - Fakes

final class StubURLProtocol: URLProtocol {
    static var statusCode = 200
    static var body = Data()

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.statusCode,
            httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class FakeOpenCodeUsageSource: OpenCodeUsageSource {
    var nextSnapshot: OpenCodeUsageSnapshot
    var nextError: OpenCodeUsageError?
    private(set) var fetchCount = 0

    init(snapshot: OpenCodeUsageSnapshot = .empty, error: OpenCodeUsageError? = nil) {
        self.nextSnapshot = snapshot
        self.nextError = error
    }

    func fetch() async throws -> OpenCodeUsageSnapshot {
        fetchCount += 1
        if let nextError { throw nextError }
        return nextSnapshot
    }
}
