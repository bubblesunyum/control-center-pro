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

    /// Whether the grant is spent. Unknown expiry counts as live — legacy
    /// logins predate the field, and the endpoint is the arbiter for those.
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() > expiresAt.addingTimeInterval(-60)
    }

    /// Merges fresh tokens into an existing credentials dict, preserving any
    /// other keys already present.
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

/// Reads the key the file holds. Legacy path — the app's own store serves
/// first and tries this file only after its prompt-free migration misses.
/// Throws nothing on a missing or unparsable file — that is just "not
/// connected", which the widget shows inline.
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

/// One-shot reads of the login Claude Code keeps in the login keychain.
///
/// Deliberately NOT a ClaudeCredentialStore: nothing on the fetch path may
/// hold one. Every access can re-prompt — dev builds re-signed on every
/// compile arrive as strangers — so ambient reads nag once per panel open
/// (see never-ambient-login-keychain-reads). The silent read backs the app
/// file's first-launch migration; the explicit read backs the Import button,
/// which is the only moment a system dialog is contextual.
public struct ClaudeKeychainLogin: Sendable {
    public static let service = "Claude Code-credentials"

    private let service: String

    public init(service: String = Self.service) {
        self.service = service
    }

    /// Reads without ever prompting: with `kSecUseAuthenticationUIFail` a
    /// build the keychain doesn't trust fails fast with
    /// `errSecInteractionNotAllowed` instead of showing Allow. Nil on any
    /// failure — the caller falls through to its next source.
    public func loadSilently() -> ClaudeOAuthCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credentials = ClaudeOAuthCredentials(oauthJSON: json)
        else { return nil }
        return credentials
    }

    /// Reads with the system prompt. Call only from the Import button —
    /// never ambiently. Nil when there is no login or the read fails.
    public func loadWithPrompt() -> ClaudeOAuthCredentials? {
        var item: CFTypeRef?
        guard SecItemCopyMatching(query(returningData: true), &item) == errSecSuccess,
              let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credentials = ClaudeOAuthCredentials(oauthJSON: json)
        else { return nil }
        return credentials
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

/// Our own copy of the Claude OAuth, in one owner-only file under
/// Application Support — the FileCraftCredentialStore shape, not the login
/// keychain.
///
/// A login-keychain item is ACL'd to the build that created it, and dev
/// builds are re-signed on every compile, so each launch arrived as a
/// stranger and macOS asked the user to vouch for it — twice per panel open.
/// A 0600 file in the app's own container is isolated by the OS and encrypted
/// at rest under FileVault, and never prompts.
///
/// The copy arrives once: the first load with no file tries a prompt-free
/// keychain read and files what it finds; otherwise the Import button copies
/// it behind one explicit prompt. Refreshes write back here — Claude Code's
/// own entry is never written.
public struct AppClaudeCredentialStore: ClaudeCredentialStore {
    private let fileURL: URL
    private let legacyFile: ClaudeCredentialStore
    private let silentLogin: @Sendable () -> ClaudeOAuthCredentials?

    public init(
        fileURL: URL? = nil,
        legacyFile: ClaudeCredentialStore = FileClaudeCredentialStore(),
        silentLogin: @Sendable @escaping () -> ClaudeOAuthCredentials? = {
            ClaudeKeychainLogin().loadSilently()
        }
    ) {
        self.fileURL = fileURL ?? URL.applicationSupport.appendingPathComponent("claude-oauth")
        self.legacyFile = legacyFile
        self.silentLogin = silentLogin
    }

    public func loadCredentials() throws -> ClaudeOAuthCredentials? {
        if let data = try? Data(contentsOf: fileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let credentials = ClaudeOAuthCredentials(oauthJSON: json)
        {
            return credentials
        }
        if let migrated = silentLogin(), !migrated.isExpired {
            // An already-expired migration is never cemented: it would shadow
            // a still-valid legacy login with a dead copy on every load after.
            try? saveCredentials(migrated)
            return migrated
        }
        return try legacyFile.loadCredentials()
    }

    public func saveCredentials(_ credentials: ClaudeOAuthCredentials) throws {
        let data = try JSONSerialization.data(
            withJSONObject: credentials.merging(into: [:]))
        try writeOwnerOnly(data)
        // Only a read-back proves the bytes landed: a throw after a
        // successful write would report "nothing was stored" while the next
        // launch reads the file as configured.
        guard (try? Data(contentsOf: fileURL)) == data else {
            throw AppClaudeCredentialError.unwritten
        }
    }

    /// Owner-only from birth, never world-readable in between: the temp file
    /// is created 0600 and renamed over the target. A crash mid-swap loses
    /// the credential (fail-safe: re-import) rather than exposing it.
    private func writeOwnerOnly(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let tmp = directory.appendingPathComponent(UUID().uuidString)
        do {
            guard FileManager.default.createFile(atPath: tmp.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw AppClaudeCredentialError.unwritten
            }
            try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}

public enum AppClaudeCredentialError: Error {
    case unwritten
}

/// One-shot copy of Claude Code's login into our private store. Runs only
/// from the Import button — never on the fetch path.
public struct ClaudeLoginImporter: Sendable {
    private let readLogin: @Sendable () -> ClaudeOAuthCredentials?
    private let store: ClaudeCredentialStore

    public init(
        readLogin: @Sendable @escaping () -> ClaudeOAuthCredentials? = {
            ClaudeKeychainLogin().loadWithPrompt()
        },
        store: ClaudeCredentialStore = AppClaudeCredentialStore()
    ) {
        self.readLogin = readLogin
        self.store = store
    }

    /// Copies the login; false when there was none to copy.
    @discardableResult
    public func importLogin() throws -> Bool {
        guard let login = readLogin() else { return false }
        try store.saveCredentials(login)
        return true
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

    private let credentials: ClaudeCredentialStore
    private let session: URLSession

    public init(
        credentials: ClaudeCredentialStore = AppClaudeCredentialStore(),
        session: URLSession = .shared
    ) {
        self.credentials = credentials
        self.session = session
    }

    public func fetch() async throws -> ClaudeUsageSnapshot {
        guard let creds = try credentials.loadCredentials(), !creds.accessToken.isEmpty,
              !creds.isExpired
        else {
            // No refresh here, deliberately: refresh tokens are single-use,
            // so minting from our copy would invalidate Claude Code's own and
            // log the user out of their real tool. An expired copy just reads
            // as logged-out until the next import re-syncs to the live login.
            throw ClaudeUsageError.missingCredentials
        }
        return try await requestUsage(token: creds.accessToken)
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
                // Revoked or rotated elsewhere — re-import re-syncs.
                throw ClaudeUsageError.missingCredentials
            default:
                // Only 401 means the token is bad. A 403 of any shape — a
                // proxy's HTML page, OAuth disallowed for the organization —
                // is an outage: mapping it to missingCredentials would loop
                // the user through re-login to no effect.
                throw ClaudeUsageError.unavailable
            }
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
