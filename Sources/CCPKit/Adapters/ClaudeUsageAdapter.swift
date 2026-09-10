// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import Observation
import Security

// MARK: - Public snapshot

/// What the Claude half of the usage card shows at one instant.
///
/// Claude publishes no monthly limit, so this is the 5-hour session window
/// and the all-models weekly window only.
public struct ClaudeUsageSnapshot: Sendable, Equatable {
    public var rolling: UsageWindow?
    public var weekly: UsageWindow?

    public init(
        rolling: UsageWindow? = nil,
        weekly: UsageWindow? = nil
    ) {
        self.rolling = rolling
        self.weekly = weekly
    }

    public static let empty = ClaudeUsageSnapshot()
}

// MARK: - Error

public enum ClaudeUsageError: Sendable, Equatable, Error {
    /// No usable OAuth anywhere — the user hasn't run `claude auth login`,
    /// or the refresh token is dead.
    case missingCredentials
    /// The login keychain entry exists but reads are denied — the user
    /// dismissed the access prompt instead of choosing Always Allow.
    case keychainDenied
    /// The endpoint was unreachable, answered something unusable, or OAuth is
    /// disallowed for the account's organization.
    case unavailable
}

// MARK: - Credentials

/// Claude Code's OAuth, as it saved it.
public struct ClaudeOAuthCredentials: Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    /// `expiresAt` in the file, milliseconds since epoch.
    public var expiresAt: Date?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Parses the `claudeAiOauth` dict both the credentials file and the
    /// login keychain hold. Nil when the login is absent or misshapen —
    /// "not connected", never an error.
    init?(oauthJSON json: [String: Any]) {
        guard let oauth = json["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String,
              !access.isEmpty
        else { return nil }
        var expiresAt: Date?
        if let millis = oauth["expiresAt"] as? Double {
            expiresAt = Date(timeIntervalSince1970: millis / 1000)
        } else if let millis = oauth["expiresAt"] as? Int {
            expiresAt = Date(timeIntervalSince1970: Double(millis) / 1000)
        }
        self.init(
            accessToken: access,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: expiresAt
        )
    }

    /// Merges fresh tokens into an existing credentials dict, preserving
    /// sibling keys — notably `mcpOAuth`, which shares the keychain entry.
    func merging(into json: [String: Any]) -> [String: Any] {
        var json = json
        var oauth = json["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = accessToken
        if let refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        if let expiresAt {
            oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
        }
        json["claudeAiOauth"] = oauth
        return json
    }
}

/// Where the Claude OAuth comes from.
///
/// The seam a test stands a fake in for: the real ones need the user's
/// login on disk or in the keychain.
public protocol ClaudeCredentialStore: Sendable {
    func loadCredentials() throws -> ClaudeOAuthCredentials?
    func saveCredentials(_ credentials: ClaudeOAuthCredentials) throws
}

/// Reads the key the file holds. Legacy path — current installs keep OAuth
/// in the login keychain and never write this file, so the compound tries
/// the keychain first. Throws nothing on a missing or unparsable file —
/// that is just "not connected", which the widget shows inline.
public struct FileClaudeCredentialStore: ClaudeCredentialStore {
    private let credentialsFile: URL

    public init(
        credentialsFile: URL? = nil
    ) {
        if let credentialsFile {
            self.credentialsFile = credentialsFile
        } else if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            self.credentialsFile = URL(fileURLWithPath: override).appending(path: ".credentials.json")
        } else {
            self.credentialsFile = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".claude/.credentials.json")
        }
    }

    public func loadCredentials() throws -> ClaudeOAuthCredentials? {
        guard let data = try? Data(contentsOf: credentialsFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return ClaudeOAuthCredentials(oauthJSON: json)
    }

    public func saveCredentials(_ credentials: ClaudeOAuthCredentials) throws {
        var json: [String: Any] =
            (try? Data(contentsOf: credentialsFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        json = credentials.merging(into: json)
        let data = try JSONSerialization.data(withJSONObject: json)
        let dir = credentialsFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(path: ".credentials.json.\(UUID().uuidString).tmp")
        // Created at 0600 before a single token byte lands, and written in
        // place so the mode sticks — the tokens are never world-readable. A
        // throw below removes the tmp rather than leaving it behind.
        FileManager.default.createFile(
            atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        do {
            try data.write(to: tmp)
            if FileManager.default.fileExists(atPath: credentialsFile.path) {
                _ = try FileManager.default.replaceItemAt(credentialsFile, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: credentialsFile)
            }
            // Replace keeps the previous file's mode, so enforce 0600 on the
            // final path either way.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: credentialsFile.path)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}

/// In-memory stand-in for tests and previews. Never ships in the app.
///
/// Unchecked Sendable because tests drive it from one actor at a time — same
/// deal as the OpenCode stand-in.
public final class InMemoryClaudeCredentialStore: ClaudeCredentialStore, @unchecked Sendable {
    private var credentials: ClaudeOAuthCredentials?

    public init(credentials: ClaudeOAuthCredentials? = nil) {
        self.credentials = credentials
    }

    public func loadCredentials() throws -> ClaudeOAuthCredentials? { credentials }

    public func saveCredentials(_ credentials: ClaudeOAuthCredentials) throws {
        self.credentials = credentials
    }
}

/// The login keychain entry Claude Code's native builds maintain.
///
/// `claude auth login` writes OAuth here under this exact service and never
/// touches the credentials file, so a file-only read misses every current
/// login. The first read prompts once — Always Allow keeps later panel opens
/// silent; a dismissal surfaces as `.keychainDenied` instead of a login nag.
public struct KeychainClaudeCredentialStore: ClaudeCredentialStore {
    public static let service = "Claude Code-credentials"

    private let service: String

    public init(service: String = Self.service) {
        self.service = service
    }

    public func loadCredentials() throws -> ClaudeOAuthCredentials? {
        var item: CFTypeRef?
        guard try entryExists(SecItemCopyMatching(query(returningData: true), &item)) else {
            return nil
        }
        guard let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credentials = ClaudeOAuthCredentials(oauthJSON: json)
        else { return nil }
        return credentials
    }

    public func saveCredentials(_ credentials: ClaudeOAuthCredentials) throws {
        // One read decides update-vs-add, so a second lookup can't disagree
        // with the first under per-access confirmation.
        var item: CFTypeRef?
        let found = try entryExists(SecItemCopyMatching(query(returningData: true), &item))
        var json: [String: Any] = [:]
        if found,
           let data = item as? Data,
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            json = raw
        }
        let data = try JSONSerialization.data(
            withJSONObject: credentials.merging(into: json))
        if found {
            _ = try entryExists(SecItemUpdate(
                query(returningData: false),
                [kSecValueData as String: data] as CFDictionary
            ))
        } else {
            var add = baseQuery
            add[kSecAttrAccount as String] = NSUserName()
            add[kSecValueData as String] = data
            let status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem {
                // Created between our read and our add — re-read for a
                // current merge base so the retry preserves whatever the
                // winner wrote (notably mcpOAuth), then update instead.
                var current: CFTypeRef?
                var base: [String: Any] = [:]
                if SecItemCopyMatching(query(returningData: true), &current) == errSecSuccess,
                   let currentData = current as? Data,
                   let raw = try? JSONSerialization.jsonObject(with: currentData) as? [String: Any]
                {
                    base = raw
                }
                let retryData = try JSONSerialization.data(
                    withJSONObject: credentials.merging(into: base))
                _ = try entryExists(SecItemUpdate(
                    query(returningData: false),
                    [kSecValueData as String: retryData] as CFDictionary
                ))
            } else {
                _ = try entryExists(status)
            }
        }
    }

    /// Maps a Security result to entry-exists. One owner so load and save
    /// can't disagree on what denial means — writes reuse it too, since a
    /// denied or failed write reads as the widget's errors either way.
    func entryExists(_ status: OSStatus) throws -> Bool {
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        case errSecAuthFailed, errSecUserCanceled:
            throw ClaudeUsageError.keychainDenied
        default:
            throw ClaudeUsageError.unavailable
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    private func query(returningData: Bool) -> CFDictionary {
        var query = baseQuery
        query[kSecReturnData as String] = returningData
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query as CFDictionary
    }
}

/// Keychain, then file — in that load order, deliberately.
///
/// Current Claude Code keeps OAuth in the login keychain and the file is the
/// legacy shape, so when both yield a login the keychain is the live one and
/// wins. Saves go back to whichever side yields usable creds, keeping load
/// and save on the same origin even when one side holds an unparsable entry.
//
// Unchecked Sendable: both wrapped stores are Sendable and skipKeychain sits
// behind the lock — fetches run off the main actor, so the flag needs it.
public final class CompoundClaudeCredentialStore: ClaudeCredentialStore, @unchecked Sendable {
    private let keychain: ClaudeCredentialStore
    private let file: ClaudeCredentialStore
    private let lock = NSLock()
    private var skipKeychain = false

    public init(
        keychain: ClaudeCredentialStore = KeychainClaudeCredentialStore(),
        file: ClaudeCredentialStore = FileClaudeCredentialStore()
    ) {
        self.keychain = keychain
        self.file = file
    }

    public func loadCredentials() throws -> ClaudeOAuthCredentials? {
        if !isSkipped {
            do {
                if let credentials = try keychain.loadCredentials() {
                    return credentials
                }
            } catch ClaudeUsageError.keychainDenied {
                // A dismissal re-prompts on every access, so stick the skip
                // for the process — but only past a working file. With no
                // file either, the denial itself is the honest error and the
                // next open re-prompts, which is the only recovery path.
                if let fileCredentials = try file.loadCredentials() {
                    setSkipped()
                    return fileCredentials
                }
                throw ClaudeUsageError.keychainDenied
            } catch {
                if let fileCredentials = try file.loadCredentials() {
                    return fileCredentials
                }
                throw ClaudeUsageError.unavailable
            }
        }
        return try file.loadCredentials()
    }

    public func saveCredentials(_ credentials: ClaudeOAuthCredentials) throws {
        if !isSkipped {
            do {
                if try keychain.loadCredentials() != nil {
                    try keychain.saveCredentials(credentials)
                    return
                }
            } catch ClaudeUsageError.keychainDenied {
                setSkipped()
            } catch {
                // A failing keychain must not strand a working file.
            }
        }
        try file.saveCredentials(credentials)
    }

    private var isSkipped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return skipKeychain
    }

    private func setSkipped() {
        lock.lock()
        defer { lock.unlock() }
        skipKeychain = true
    }
}

// MARK: - Source

/// Where Claude quota numbers come from.
///
/// The seam a test stands a fake in for: the real one needs a network round
/// trip and the user's login, neither of which a test can arrange.
public protocol ClaudeUsageSource: AnyObject, Sendable {
    func fetch() async throws -> ClaudeUsageSnapshot
}

/// The real one, against Anthropic's OAuth usage endpoint — the same numbers
/// `/usage` and the status line show.
public final class LiveClaudeUsageSource: ClaudeUsageSource {
    private static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    /// Claude Code's public OAuth client — one id for every client, safe to ship.
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private let credentials: ClaudeCredentialStore
    private let session: URLSession

    public init(
        credentials: ClaudeCredentialStore = CompoundClaudeCredentialStore(),
        session: URLSession = .shared
    ) {
        self.credentials = credentials
        self.session = session
    }

    public func fetch() async throws -> ClaudeUsageSnapshot {
        guard var creds = try credentials.loadCredentials(), !creds.accessToken.isEmpty else {
            throw ClaudeUsageError.missingCredentials
        }
        // Refresh proactively when expired — the access token lives ~an hour.
        // A blipped token endpoint must not sink the fetch: the loaded token
        // may still be good, so only a dead refresh token reads as logged-out.
        if isExpired(creds) {
            creds = try await freshCredentials(creds)
        }
        do {
            return try await requestUsage(token: creds.accessToken)
        } catch FetchFailure.unauthorized {
            let token = try await refreshAfterRejection(creds)
            do {
                return try await requestUsage(token: token)
            } catch FetchFailure.unauthorized {
                // The minted token is rejected too — the grant is gone.
                throw ClaudeUsageError.missingCredentials
            }
        }
    }

    /// Current credentials, refreshing when expired. Re-reads first: Claude
    /// Code rotates on its own schedule, and refreshing over its write with a
    /// consumed refresh token would log the user out. The re-read never sinks
    /// the fetch — a dismissal just means refreshing from the in-hand creds.
    private func freshCredentials(_ creds: ClaudeOAuthCredentials) async throws -> ClaudeOAuthCredentials {
        if let latest = try? credentials.loadCredentials(),
           latest.accessToken != creds.accessToken, !latest.accessToken.isEmpty
        {
            return latest
        }
        do {
            return try await refresh(creds)
        } catch ClaudeUsageError.unavailable {
            return creds
        }
    }

    /// One recovery round after a 401: prefer whatever is on disk now — it may
    /// be newer than what this fetch loaded — and refresh only from there.
    private func refreshAfterRejection(_ creds: ClaudeOAuthCredentials) async throws -> String {
        if let latest = try? credentials.loadCredentials(),
           latest.accessToken != creds.accessToken, !latest.accessToken.isEmpty
        {
            return latest.accessToken
        }
        return try await refresh(creds).accessToken
    }

    private func requestUsage(token: String) async throws -> ClaudeUsageSnapshot {
        var request = URLRequest(
            url: Self.usageEndpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Without this beta the endpoint answers an auth error.
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ControlCenterPro", forHTTPHeaderField: "User-Agent")
        let data: Data
        do {
            let (body, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                data = body
            case 401:
                throw FetchFailure.unauthorized
            default:
                // Only 401 means the token is bad. A 403 of any shape — a
                // proxy's HTML page, OAuth disallowed for the organization —
                // is an outage: mapping it to missingCredentials would loop
                // the user through re-login to no effect.
                throw ClaudeUsageError.unavailable
            }
        } catch let failure as FetchFailure {
            throw failure
        } catch let error as ClaudeUsageError {
            throw error
        } catch {
            throw ClaudeUsageError.unavailable
        }
        do {
            return try Self.decodeSnapshot(from: data)
        } catch {
            throw ClaudeUsageError.unavailable
        }
    }

    /// One refresh round trip, persisted. A dead refresh token reads as
    /// "log in again", not "offline".
    private func refresh(_ creds: ClaudeOAuthCredentials) async throws -> ClaudeOAuthCredentials {
        guard let refreshToken = creds.refreshToken, !refreshToken.isEmpty else {
            throw ClaudeUsageError.missingCredentials
        }
        var request = URLRequest(
            url: Self.tokenEndpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ])
        let payload: [String: Any]
        let access: String
        do {
            let (body, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let token = json["access_token"] as? String, !token.isEmpty
            else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw RefreshFailure(status: status)
            }
            payload = json
            access = token
        } catch let failure as RefreshFailure {
            // The refresh token itself is rejected — only a fresh login fixes it.
            if failure.status == 400 || failure.status == 401 {
                throw ClaudeUsageError.missingCredentials
            }
            throw ClaudeUsageError.unavailable
        } catch let error as ClaudeUsageError {
            throw error
        } catch {
            throw ClaudeUsageError.unavailable
        }
        var refreshed = creds
        refreshed.accessToken = access
        // Refresh tokens rotate: dropping the new one logs the user out.
        if let next = payload["refresh_token"] as? String, !next.isEmpty {
            refreshed.refreshToken = next
        }
        if let lifetime = payload["expires_in"] as? Double {
            refreshed.expiresAt = Date().addingTimeInterval(lifetime)
        } else if let lifetime = payload["expires_in"] as? Int {
            refreshed.expiresAt = Date().addingTimeInterval(Double(lifetime))
        }
        // Best effort — and never over a newer login or a logout: a
        // `claude auth login` (or logout) landing mid-refresh wins, while our
        // minted tokens still serve this fetch. An unverifiable re-read also
        // skips the save rather than risking it. A failed write just means
        // the next fetch refreshes again.
        do {
            guard let current = try credentials.loadCredentials() else {
                return refreshed
            }
            guard current.accessToken == creds.accessToken else {
                return refreshed
            }
        } catch {
            return refreshed
        }
        try? credentials.saveCredentials(refreshed)
        return refreshed
    }

    private func isExpired(_ creds: ClaudeOAuthCredentials) -> Bool {
        guard let expiresAt = creds.expiresAt else { return false }
        return Date() > expiresAt.addingTimeInterval(-60)
    }

    /// Tolerantly decoded: unknown `kind`s and model-scoped weeklies are
    /// skipped rather than failing the whole snapshot, so a newly added
    /// bucket can never blank the card.
    static func decodeSnapshot(from data: Data) throws -> ClaudeUsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = json["limits"] as? [Any]
        else { throw ClaudeUsageError.unavailable }
        var snapshot = ClaudeUsageSnapshot()
        for case let entry as [String: Any] in limits {
            guard let kind = entry["kind"] as? String,
                  let percent = finitePercent(entry["percent"])
            else { continue }
            let resetsAt = (entry["resets_at"] as? String).flatMap(parseReset)
            switch kind {
            case "session":
                snapshot.rolling = UsageWindow(percent: percent, resetsAt: resetsAt)
            case "weekly_all":
                snapshot.weekly = UsageWindow(percent: percent, resetsAt: resetsAt)
            default:
                continue
            }
        }
        return snapshot
    }

    private static func finitePercent(_ value: Any?) -> Double? {
        let percent: Double?
        if let number = value as? Double {
            percent = number
        } else if let number = value as? Int {
            percent = Double(number)
        } else {
            return nil
        }
        guard let percent, percent.isFinite, (0...100).contains(percent) else { return nil }
        return percent
    }

    private static func parseReset(_ raw: String) -> Date? {
        UsageDateFormatter.withFractional.date(from: raw)
            ?? UsageDateFormatter.withoutFractional.date(from: raw)
    }
}

private enum FetchFailure: Error {
    case unauthorized
}

private struct RefreshFailure: Error {
    var status: Int
}

// MARK: - Adapter

/// The Claude half's model: fetches quota while the panel is open, idles at
/// 0% when shut.
///
/// Same contract as `OpenCodeUsageAdapter` — one fetch per panel open at
/// most behind a 60s cache, reset countdowns ticking locally off `resetsAt`
/// on an adapter-owned timer — so the widget can fan `activate()` out to
/// both halves without knowing which is which.
@MainActor
@Observable
public final class ClaudeUsageAdapter {
    public private(set) var snapshot: ClaudeUsageSnapshot
    public private(set) var lastUpdated: Date?
    public private(set) var lastError: ClaudeUsageError?
    /// Ticks every 30s while open so "3h 12m" stays honest.
    public private(set) var now = Date()

    @ObservationIgnored private let source: ClaudeUsageSource
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private let cacheTTL: Duration

    public static let defaultCacheTTL = Duration.seconds(60)

    public convenience init() {
        self.init(source: LiveClaudeUsageSource())
    }

    public init(
        source: ClaudeUsageSource,
        cacheTTL: Duration = defaultCacheTTL,
        initialSnapshot: ClaudeUsageSnapshot = .empty
    ) {
        self.source = source
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
        } catch is CancellationError {
            return
        } catch let error as ClaudeUsageError {
            guard !Task.isCancelled else { return }
            self.lastError = error
        } catch {
            guard !Task.isCancelled else { return }
            self.lastError = .unavailable
        }
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
