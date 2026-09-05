// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import Observation

// MARK: - Public snapshot

/// One quota window from the Go plan usage endpoint.
public struct OpenCodeUsageWindow: Sendable, Equatable {
    /// Used percentage, 0...100 as reported.
    public var percent: Double
    public var resetsAt: Date?
    public var isRateLimited: Bool

    public init(percent: Double, resetsAt: Date? = nil, isRateLimited: Bool = false) {
        self.percent = percent
        self.resetsAt = resetsAt
        self.isRateLimited = isRateLimited
    }
}

/// What the OpenCode usage card shows at one instant.
public struct OpenCodeUsageSnapshot: Sendable, Equatable {
    public var rolling: OpenCodeUsageWindow?
    public var weekly: OpenCodeUsageWindow?
    public var monthly: OpenCodeUsageWindow?

    public init(
        rolling: OpenCodeUsageWindow? = nil,
        weekly: OpenCodeUsageWindow? = nil,
        monthly: OpenCodeUsageWindow? = nil
    ) {
        self.rolling = rolling
        self.weekly = weekly
        self.monthly = monthly
    }

    public static let empty = OpenCodeUsageSnapshot()
}

// MARK: - Error

public enum OpenCodeUsageError: Sendable, Equatable, Error {
    /// No `opencode-go` key in auth.json — the user hasn't connected Go.
    case missingCredentials
    /// The endpoint was unreachable or answered something unusable.
    case unavailable
}

// MARK: - Credentials

/// Where the Go API key comes from.
///
/// The key is OpenCode's own, saved by `/connect` in
/// `~/.local/share/opencode/auth.json` — CCP reads it, never asks for it,
/// and never writes it anywhere.
public protocol OpenCodeCredentialStore: Sendable {
    func loadAPIKey() throws -> String?
}

/// Reads the key OpenCode saved. Throws nothing on a missing or unparsable
/// file — that is just "not connected", which the widget shows inline.
public struct FileOpenCodeCredentialStore: OpenCodeCredentialStore {
    private let authFile: URL

    public init(
        authFile: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/share/opencode/auth.json")
    ) {
        self.authFile = authFile
    }

    public func loadAPIKey() throws -> String? {
        guard let data = try? Data(contentsOf: authFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = json["opencode-go"] as? [String: Any],
              let key = entry["key"] as? String,
              !key.isEmpty
        else { return nil }
        return key
    }
}

/// In-memory stand-in for tests and previews. Never ships in the app.
public final class InMemoryOpenCodeCredentialStore: OpenCodeCredentialStore, @unchecked Sendable {
    private var key: String?

    public init(key: String? = nil) {
        self.key = key
    }

    public func loadAPIKey() throws -> String? { key }
}

// MARK: - Source

/// Where quota numbers come from.
///
/// The seam a test stands a fake in for: the real one needs a network round
/// trip and the user's API key, neither of which a test can arrange.
public protocol OpenCodeUsageSource: AnyObject, Sendable {
    func fetch() async throws -> OpenCodeUsageSnapshot
}

/// The real one, against the Go plan usage endpoint.
public final class LiveOpenCodeUsageSource: OpenCodeUsageSource {
    private static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    private let credentials: OpenCodeCredentialStore
    private let session: URLSession

    public init(
        credentials: OpenCodeCredentialStore = FileOpenCodeCredentialStore(),
        session: URLSession = .shared
    ) {
        self.credentials = credentials
        self.session = session
    }

    public func fetch() async throws -> OpenCodeUsageSnapshot {
        guard let key = try credentials.loadAPIKey() else {
            throw OpenCodeUsageError.missingCredentials
        }
        var request = URLRequest(
            url: Self.endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The gateway 403s broad/bot user agents — a tool must identify
        // itself — so this names the app rather than sending the default.
        request.setValue("ControlCenterPro", forHTTPHeaderField: "User-Agent")
        let data: Data
        do {
            let (body, response) = try await session.data(for: request)
            // `data(for:)` only throws on transport failure — an expired key
            // answers 401 with an error body, which must read as "reconnect",
            // not "offline", or the widget shows a dead end with no fix.
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                data = body
            case 401, 403:
                throw OpenCodeUsageError.missingCredentials
            default:
                throw OpenCodeUsageError.unavailable
            }
        } catch let error as OpenCodeUsageError {
            throw error
        } catch {
            throw OpenCodeUsageError.unavailable
        }
        do {
            return try Self.decodeSnapshot(from: data)
        } catch {
            throw OpenCodeUsageError.unavailable
        }
    }

    /// Tolerantly decoded: `percent` arrives as a bare int today and the
    /// widget must not break the day it arrives as a float.
    static func decodeSnapshot(from data: Data) throws -> OpenCodeUsageSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = OpenCodeUsageDateFormatter.withFractional.date(from: raw)
                ?? OpenCodeUsageDateFormatter.withoutFractional.date(from: raw)
            {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not an ISO 8601 date: \(raw)")
        }
        let payload = try decoder.decode(Payload.self, from: data)
        return OpenCodeUsageSnapshot(
            rolling: payload.usage.rolling?.window,
            weekly: payload.usage.weekly?.window,
            monthly: payload.usage.monthly?.window
        )
    }
}

private enum OpenCodeUsageDateFormatter {
    static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let withoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private struct Payload: Decodable {
    var usage: Windows

    struct Windows: Decodable {
        var rolling: Entry?
        var weekly: Entry?
        var monthly: Entry?
    }

    struct Entry: Decodable {
        var percent: Double
        var resetsAt: Date?
        var status: String?

        enum CodingKeys: String, CodingKey {
            case percent
            case resetsAt
            case status
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let percent = try? container.decode(Double.self, forKey: .percent) {
                self.percent = percent
            } else if let percent = try? container.decode(Int.self, forKey: .percent) {
                self.percent = Double(percent)
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .percent, in: container,
                    debugDescription: "percent is neither a number nor an int")
            }
            self.resetsAt = try? container.decode(Date.self, forKey: .resetsAt)
            self.status = try? container.decode(String.self, forKey: .status)
        }

        var window: OpenCodeUsageWindow {
            OpenCodeUsageWindow(
                percent: percent,
                resetsAt: resetsAt,
                isRateLimited: status == "rate-limited"
            )
        }
    }
}

// MARK: - Adapter

/// The widget's model: fetches quota while the panel is open, idles at 0%
/// when shut.
///
/// One fetch per panel open at most — a 60s cache covers open-close-open —
/// and the reset countdowns tick locally off `resetsAt` on an adapter-owned
/// timer, so nothing view-owned survives the panel closing.
@MainActor
@Observable
public final class OpenCodeUsageAdapter {
    public private(set) var snapshot: OpenCodeUsageSnapshot
    public private(set) var lastUpdated: Date?
    public private(set) var lastError: OpenCodeUsageError?
    /// Whether the shown percents are ledger-precise decimals rather than the
    /// endpoint's truncated ints.
    public private(set) var isPrecise = false
    /// Ticks every 30s while open so "resets in 3h 12m" stays honest.
    public private(set) var now = Date()

    @ObservationIgnored private let source: OpenCodeUsageSource
    @ObservationIgnored private let spend: OpenCodeSpendStore?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private let cacheTTL: Duration

    public static let defaultCacheTTL = Duration.seconds(60)

    public convenience init() {
        self.init(source: LiveOpenCodeUsageSource())
    }

    public init(
        source: OpenCodeUsageSource,
        spend: OpenCodeSpendStore? = SQLiteOpenCodeSpendStore(),
        cacheTTL: Duration = defaultCacheTTL,
        initialSnapshot: OpenCodeUsageSnapshot = .empty
    ) {
        self.source = source
        self.spend = spend
        self.cacheTTL = cacheTTL
        self.snapshot = initialSnapshot
    }

    /// Fetch unless a fresh snapshot is already held. Idempotent — a second
    /// open while a fetch is in flight does not stack another request, and the
    /// countdown ticker runs for every open regardless of cache freshness.
    public func activate() {
        startTicker()
        guard task == nil, isStale else { return }
        generation += 1
        let current = generation
        task = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            // Only clear our own handle: a close-then-reopen between the last
            // await and here must not orphan the newer fetch.
            if self.generation == current { self.task = nil }
        }
    }

    /// Stop the fetch and the ticker. Cancels synchronously so a shut panel
    /// costs nothing even if the response was due in milliseconds.
    public func deactivate() {
        task?.cancel()
        task = nil
        stopTicker()
    }

    public var isFetching: Bool { task != nil }

    /// One fetch, published on main. Useful for tests and for pull-to-refresh
    /// if the widget ever grows one.
    public func refresh() async {
        do {
            let snapshot = try await source.fetch()
            guard !Task.isCancelled else { return }
            self.snapshot = snapshot
            self.lastUpdated = Date()
            self.lastError = nil
            await refine(snapshot: snapshot)
        } catch is CancellationError {
            return
        } catch let error as OpenCodeUsageError {
            guard !Task.isCancelled else { return }
            self.lastError = error
        } catch {
            guard !Task.isCancelled else { return }
            self.lastError = .unavailable
        }
    }

    /// Replace the endpoint's truncated ints with ledger-precise decimals.
    /// A failed spend read is not an error — the endpoint's ints are still
    /// shown, just coarsely.
    private func refine(snapshot: OpenCodeUsageSnapshot) async {
        guard let spend else {
            isPrecise = false
            return
        }
        let starts = OpenCodeWindowStarts.from(
            resets: (
                snapshot.rolling?.resetsAt,
                snapshot.weekly?.resetsAt,
                snapshot.monthly?.resetsAt
            ),
            now: Date()
        )
        guard let windows = try? await spend.spend(since: starts),
              !Task.isCancelled
        else {
            isPrecise = false
            return
        }
        self.snapshot = OpenCodeUsageSnapshot(
            rolling: precise(snapshot.rolling, spend: windows.rolling, def: .rolling),
            weekly: precise(snapshot.weekly, spend: windows.weekly, def: .weekly),
            monthly: precise(snapshot.monthly, spend: windows.monthly, def: .monthly)
        )
        isPrecise = true
    }

    private func precise(
        _ window: OpenCodeUsageWindow?,
        spend: Double,
        def: OpenCodeUsageWindowDef
    ) -> OpenCodeUsageWindow? {
        guard var window else { return nil }
        window.percent = spend / def.limitDollars * 100
        return window
    }

    private var isStale: Bool {
        guard let lastUpdated else { return true }
        let elapsed = Date().timeIntervalSince(lastUpdated)
        let (seconds, attoseconds) = cacheTTL.components
        let threshold = Double(seconds) + Double(attoseconds) / 1_000_000_000_000_000_000
        return elapsed >= threshold
    }

    private func startTicker() {
        guard ticker == nil else { return }
        now = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.now = Date()
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
