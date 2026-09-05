// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
@testable import CCPKit
import SQLite3
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
        let adapter = OpenCodeUsageAdapter(source: source, spend: nil)

        await adapter.refresh()

        XCTAssertEqual(adapter.snapshot.rolling?.percent, 12.5)
        XCTAssertEqual(adapter.snapshot.weekly?.percent, 30)
        XCTAssertEqual(adapter.snapshot.monthly?.percent, 45)
        XCTAssertNil(adapter.lastError)
        XCTAssertNotNil(adapter.lastUpdated)
    }

    func testFailedFetchKeepsPreviousSnapshotAndSurfacesError() async {
        let source = FakeOpenCodeUsageSource(error: .unavailable)
        let adapter = OpenCodeUsageAdapter(source: source, spend: nil)

        await adapter.refresh()

        XCTAssertEqual(adapter.snapshot, .empty)
        XCTAssertEqual(adapter.lastError, .unavailable)
        XCTAssertNil(adapter.lastUpdated)
    }

    func testMissingCredentialsSurfacesInlineState() async {
        let source = FakeOpenCodeUsageSource(error: .missingCredentials)
        let adapter = OpenCodeUsageAdapter(source: source, spend: nil)

        await adapter.refresh()

        XCTAssertEqual(adapter.lastError, .missingCredentials)
    }

    func testSuccessfulFetchClearsPreviousError() async {
        let source = FakeOpenCodeUsageSource(error: .unavailable)
        let adapter = OpenCodeUsageAdapter(source: source, spend: nil)
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
        let adapter = OpenCodeUsageAdapter(source: source, spend: nil)

        adapter.activate()
        _ = await becomesTrue { source.fetchCount >= 1 }
        adapter.activate()

        XCTAssertEqual(source.fetchCount, 1)
        adapter.deactivate()
    }

    func testActivateRefetchesOnceCacheExpires() async {
        let source = FakeOpenCodeUsageSource(snapshot: OpenCodeUsageSnapshot(
            rolling: OpenCodeUsageWindow(percent: 5)))
        let adapter = OpenCodeUsageAdapter(source: source, spend: nil, cacheTTL: .milliseconds(20))

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
        let adapter = OpenCodeUsageAdapter(source: source, spend: nil)
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

    // MARK: - Precise percents from ledger spend

    func testRefinesTruncatedIntsWithLedgerSpend() async {
        let resets = Date()
        let source = FakeOpenCodeUsageSource(snapshot: OpenCodeUsageSnapshot(
            rolling: OpenCodeUsageWindow(percent: 3, resetsAt: resets),
            weekly: OpenCodeUsageWindow(percent: 4, resetsAt: resets),
            monthly: OpenCodeUsageWindow(percent: 2, resetsAt: resets)
        ))
        let spend = FakeOpenCodeSpendStore(windows: OpenCodeSpendWindows(
            rolling: 0.468, weekly: 1.44, monthly: 1.44))
        let adapter = OpenCodeUsageAdapter(source: source, spend: spend)

        await adapter.refresh()

        XCTAssertEqual(adapter.snapshot.rolling?.percent ?? -1, 3.9, accuracy: 1e-9)
        XCTAssertEqual(adapter.snapshot.weekly?.percent ?? -1, 4.8, accuracy: 1e-9)
        XCTAssertEqual(adapter.snapshot.monthly?.percent ?? -1, 2.4, accuracy: 1e-9)
        XCTAssertTrue(adapter.isPrecise)
        // Resets and status still come from the endpoint.
        XCTAssertEqual(adapter.snapshot.rolling?.resetsAt, resets)
    }

    func testFallsBackToServerIntsWhenSpendUnreadable() async {
        let source = FakeOpenCodeUsageSource(snapshot: OpenCodeUsageSnapshot(
            rolling: OpenCodeUsageWindow(percent: 3)))
        let adapter = OpenCodeUsageAdapter(source: source, spend: ThrowingSpendStore())

        await adapter.refresh()

        XCTAssertEqual(adapter.snapshot.rolling?.percent, 3)
        XCTAssertFalse(adapter.isPrecise)
        XCTAssertNil(adapter.lastError)
    }

    func testNilSpendStoreShowsServerInts() async {
        let source = FakeOpenCodeUsageSource(snapshot: OpenCodeUsageSnapshot(
            rolling: OpenCodeUsageWindow(percent: 3)))
        let adapter = OpenCodeUsageAdapter(source: source, spend: nil)

        await adapter.refresh()

        XCTAssertEqual(adapter.snapshot.rolling?.percent, 3)
        XCTAssertFalse(adapter.isPrecise)
    }

    // MARK: - Window starts

    func testWindowsAnchorAtResetMinusLength() {
        let reset = Date(timeIntervalSince1970: 1_000_000)
        let starts = OpenCodeWindowStarts.from(
            resets: (reset, reset, reset), now: Date(timeIntervalSince1970: 2_000_000))

        XCTAssertEqual(starts.rolling, reset.addingTimeInterval(-5 * 3600))
        XCTAssertEqual(starts.weekly, reset.addingTimeInterval(-7 * 86400))
        XCTAssertEqual(starts.monthly, reset.addingTimeInterval(-30 * 86400))
    }

    func testWeeklyFallbackIsMondayMidnightUTC() {
        let utc = Calendar.utcGregorian
        // Thursday 2026-09-03 18:00 UTC -> Monday 2026-08-31 00:00 UTC.
        let wednesday = utc.date(from: DateComponents(
            year: 2026, month: 9, day: 3, hour: 18))!
        let starts = OpenCodeWindowStarts.from(
            resets: (nil, nil, nil), now: wednesday, calendar: utc)

        XCTAssertEqual(
            starts.weekly,
            utc.date(from: DateComponents(year: 2026, month: 8, day: 31))!)
    }

    func testWeeklyFallbackOnMondayIsThatMorning() {
        let utc = Calendar.utcGregorian
        let mondayNoon = utc.date(from: DateComponents(
            year: 2026, month: 9, day: 7, hour: 12))!
        let starts = OpenCodeWindowStarts.from(
            resets: (nil, nil, nil), now: mondayNoon, calendar: utc)

        XCTAssertEqual(
            starts.weekly,
            utc.date(from: DateComponents(year: 2026, month: 9, day: 7))!)
    }

    func testRollingAndMonthlyFallbacksTrailNow() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let starts = OpenCodeWindowStarts.from(
            resets: (nil, nil, nil), now: now)

        XCTAssertEqual(starts.rolling, now.addingTimeInterval(-5 * 3600))
        XCTAssertEqual(starts.monthly, now.addingTimeInterval(-30 * 86400))
    }

    // MARK: - SQLite spend store

    func testSQLiteStoreSumsSessionCostPerWindow() throws {
        let hour: TimeInterval = 3600
        let now = Date()
        let db = try makeSpendDB(costs: [
            (0.10, now.addingTimeInterval(-1 * hour)),
            (0.20, now.addingTimeInterval(-3 * 24 * hour)),
            (0.40, now.addingTimeInterval(-10 * 24 * hour)),
        ])
        let starts = OpenCodeWindowStarts(
            rolling: now.addingTimeInterval(-5 * hour),
            weekly: now.addingTimeInterval(-7 * 24 * hour),
            monthly: now.addingTimeInterval(-30 * 24 * hour))

        let windows = try SQLiteOpenCodeSpendStore.query(dbFile: db, starts: starts)

        XCTAssertEqual(windows.rolling, 0.10, accuracy: 1e-9)
        XCTAssertEqual(windows.weekly, 0.30, accuracy: 1e-9)
        XCTAssertEqual(windows.monthly, 0.70, accuracy: 1e-9)
    }

    func testSQLiteStoreThrowsForMissingFile() {
        let now = Date()
        let starts = OpenCodeWindowStarts(rolling: now, weekly: now, monthly: now)

        XCTAssertThrowsError(try SQLiteOpenCodeSpendStore.query(
            dbFile: URL(fileURLWithPath: "/nonexistent/opencode.db"), starts: starts))
    }

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

struct FakeOpenCodeSpendStore: OpenCodeSpendStore {
    var windows: OpenCodeSpendWindows

    func spend(since starts: OpenCodeWindowStarts) async throws -> OpenCodeSpendWindows {
        windows
    }
}

struct ThrowingSpendStore: OpenCodeSpendStore {
    func spend(since starts: OpenCodeWindowStarts) async throws -> OpenCodeSpendWindows {
        throw OpenCodeSpendError.unreadable
    }
}

/// A throwaway ledger with the shape the spend query reads.
func makeSpendDB(costs: [(cost: Double, updated: Date)]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "ccp-spend-\(UUID().uuidString).db")
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
        throw OpenCodeSpendError.unreadable
    }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(
        db,
        "CREATE TABLE session (id TEXT PRIMARY KEY, cost REAL DEFAULT 0 NOT NULL, time_updated INTEGER NOT NULL)",
        nil, nil, nil) == SQLITE_OK
    else { throw OpenCodeSpendError.unreadable }

    var insert: OpaquePointer?
    guard sqlite3_prepare_v2(
        db, "INSERT INTO session (id, cost, time_updated) VALUES (?1, ?2, ?3)",
        -1, &insert, nil) == SQLITE_OK, let query = insert
    else { throw OpenCodeSpendError.unreadable }
    defer { sqlite3_finalize(query) }
    for (index, entry) in costs.enumerated() {
        sqlite3_bind_text(query, 1, "ses-\(index)", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_double(query, 2, entry.cost)
        sqlite3_bind_int64(query, 3, Int64(entry.updated.timeIntervalSince1970 * 1000))
        guard sqlite3_step(query) == SQLITE_DONE else { throw OpenCodeSpendError.unreadable }
        sqlite3_reset(query)
    }
    return url
}
