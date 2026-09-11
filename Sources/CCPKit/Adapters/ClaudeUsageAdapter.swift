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
    /// The pasted setup-token was rejected. Distinct from missing: the fix
    /// is a fresh paste in Settings, not an import.
    case invalidToken
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
    /// The freshest login held outside our own copy, if any — the CLI's
    /// legacy file for the app store, nothing for the others. The usage
    /// source tries this once after a 401 before reporting logged-out,
    /// so a revoked copy heals when the CLI's file is live.
    func loadFallbackCredentials() throws -> ClaudeOAuthCredentials?
}

extension ClaudeCredentialStore {
    public func loadFallbackCredentials() throws -> ClaudeOAuthCredentials? { nil }
}

/// Reads the key the file holds. Legacy path — the app's own store
/// live-reads this file alongside its copy on every load.
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
/// hold one. A keychain read from this app can present a system prompt even
/// when asked not to — observed 2026-09-11, every panel open prompted —
/// because the item is ACL'd to the build that created it. So the only
/// keychain touch is the explicit read behind the Import button, which is
/// the one moment a system dialog is contextual.
public struct ClaudeKeychainLogin: Sendable {
    public static let service = "Claude Code-credentials"

    private let service: String

    public init(service: String = Self.service) {
        self.service = service
    }

    /// Reads with the system prompt. Call only from the Import button —
    /// never ambiently. Nil when there is no login or the read fails.
    public func loadWithPrompt() -> ClaudeOAuthCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
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
}

/// Our own copy of the Claude OAuth, in one owner-only file under
/// Application Support — the FileCraftCredentialStore shape, not the login
/// keychain.
///
/// Reads on the fetch path are files only: ours and the CLI's legacy file.
/// A login-keychain read can present a system prompt even when asked not to
/// (observed 2026-09-11: every panel open prompted), so the keychain is
/// touched solely behind the Import button, where a dialog is contextual.
/// Our file is written only by that import and by a 401-verified heal —
/// never speculatively — so a rotation can never be shadowed by a stale
/// copy. Refreshes are never minted here — refresh tokens are single-use,
/// so minting from our copy would invalidate Claude Code's own — and
/// Claude Code's entry is never written.
public struct AppClaudeCredentialStore: ClaudeCredentialStore {
    private let fileURL: URL
    private let legacyFile: ClaudeCredentialStore

    public init(
        fileURL: URL? = nil,
        legacyFile: ClaudeCredentialStore = FileClaudeCredentialStore()
    ) {
        self.fileURL = fileURL ?? URL.applicationSupport.appendingPathComponent("claude-oauth")
        self.legacyFile = legacyFile
    }

    public func loadCredentials() throws -> ClaudeOAuthCredentials? {
        let appCreds = loadAppFile()
        let legacy = try? legacyFile.loadCredentials()
        // Freshest live credential wins; ties break toward our copy for
        // stability — a dead copy still heals via the 401 retry below.
        return Self.freshest(app: appCreds, legacy: legacy)
    }

    public func loadFallbackCredentials() throws -> ClaudeOAuthCredentials? {
        let legacy = try? legacyFile.loadCredentials()
        guard let legacy, !legacy.isExpired else { return nil }
        return legacy
    }

    /// Freshest live credential wins; ties prefer our copy. Unknown expiry
    /// counts as live (legacy logins predate the field) but sorts below
    /// any dated credential.
    private static func freshest(
        app: ClaudeOAuthCredentials?,
        legacy: ClaudeOAuthCredentials?
    ) -> ClaudeOAuthCredentials? {
        [(app, 1), (legacy, 0)]
            .compactMap { creds, priority -> (ClaudeOAuthCredentials, Int)? in
                guard let creds, !creds.isExpired else { return nil }
                return (creds, priority)
            }
            .max { lhs, rhs in
                let lhsExpiry = lhs.0.expiresAt ?? .distantPast
                let rhsExpiry = rhs.0.expiresAt ?? .distantPast
                if lhsExpiry != rhsExpiry { return lhsExpiry < rhsExpiry }
                return lhs.1 < rhs.1
            }?.0
    }

    private func loadAppFile() -> ClaudeOAuthCredentials? {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return ClaudeOAuthCredentials(oauthJSON: json)
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

    /// The shared owner-only writer; the store's own error keeps the
    /// throw site's type stable for callers matching on it.
    private func writeOwnerOnly(_ data: Data) throws {
        do {
            try OwnerOnlyFileWriter.write(data, to: fileURL)
        } catch OwnerOnlyFileWriter.Error.unwritten {
            throw AppClaudeCredentialError.unwritten
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

// MARK: - Static token

/// Where the pasted `claude setup-token` comes from.
///
/// A setup-token authenticates as the subscription without an hourly
/// expiry, so it outranks the imported login copy: when one is stored the
/// fetch path never consults the imported copy at all. Raw trimmed bytes —
/// the endpoint arbitrates the shape, never the store.
public protocol ClaudeStaticTokenStore: Sendable {
    func loadToken() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

/// The token as UTF-8 bytes in one owner-only file under Application
/// Support. Never prompts, never touches the keychain — Settings is the
/// only writer.
public struct FileClaudeStaticTokenStore: ClaudeStaticTokenStore {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? URL.applicationSupport.appendingPathComponent("claude-token")
    }

    public func loadToken() throws -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let token = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    public func saveToken(_ token: String) throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ClaudeStaticTokenError.empty }
        try writeOwnerOnly(Data(token.utf8))
        // Only a read-back proves the bytes landed: a throw after a
        // successful write would report "nothing was stored" while the next
        // launch reads the file as configured.
        guard (try? loadToken()) == token else {
            throw ClaudeStaticTokenError.unwritten
        }
    }

    public func deleteToken() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already gone is gone.
        }
    }

    /// The shared owner-only writer; the store's own error keeps the
    /// throw site's type stable for callers matching on it.
    private func writeOwnerOnly(_ data: Data) throws {
        do {
            try OwnerOnlyFileWriter.write(data, to: fileURL)
        } catch OwnerOnlyFileWriter.Error.unwritten {
            throw ClaudeStaticTokenError.unwritten
        }
    }
}

public enum ClaudeStaticTokenError: Error {
    case empty
    case unwritten
}

/// In-memory stand-in for tests and previews. Never ships in the app.
///
/// Unchecked Sendable because tests drive it from one actor at a time — same
/// deal as the OpenCode stand-in.
public final class InMemoryClaudeStaticTokenStore: ClaudeStaticTokenStore, @unchecked Sendable {
    private var token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    public func loadToken() throws -> String? { token }

    public func saveToken(_ token: String) throws {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func deleteToken() throws {
        token = nil
    }
}

/// What the Settings row shows. The stored token itself is never exposed —
/// it is the credential, and a field that echoes it leaks it onto the
/// screen.
public enum ClaudeTokenStatus: Equatable, Sendable {
    case notConfigured
    case saved
    case storeFailed
}

/// Owns the pasted setup-token behind the Settings section. Entry only —
/// never refilled from the store: once saved, the field clears and the
/// token is not shown again.
@MainActor
@Observable
public final class ClaudeTokenModel {
    public var tokenText: String = ""
    public private(set) var status: ClaudeTokenStatus = .notConfigured
    /// Cached so view bodies do not touch disk on every evaluation.
    public private(set) var isConfigured = false

    @ObservationIgnored private let store: any ClaudeStaticTokenStore

    public convenience init() {
        self.init(store: FileClaudeStaticTokenStore())
    }

    public init(store: any ClaudeStaticTokenStore) {
        self.store = store
        isConfigured = (try? store.loadToken()) != nil
        if isConfigured { status = .saved }
    }

    public var statusText: String {
        switch status {
        case .notConfigured: "Not connected"
        case .saved: "Token saved"
        case .storeFailed: "Not saved"
        }
    }

    /// Store the entered text. A store failure keeps the entered text in the
    /// field — the user should not have to fetch the token a second time.
    public func save() {
        let token = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            try store.saveToken(token)
        } catch {
            status = .storeFailed
            return
        }
        tokenText = ""
        isConfigured = true
        status = .saved
    }

    /// Forgets the token. Reports success only when it is actually gone —
    /// the UI must never claim a credential is destroyed while it is still
    /// stored.
    public func forget() {
        do {
            try store.deleteToken()
        } catch {
            status = .storeFailed
            return
        }
        isConfigured = false
        status = .notConfigured
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
    private let staticToken: any ClaudeStaticTokenStore
    private let session: URLSession

    public convenience init() {
        self.init(
            credentials: AppClaudeCredentialStore(),
            staticToken: FileClaudeStaticTokenStore(),
            session: .shared
        )
    }

    /// Tests pass both stores explicitly so no test ever touches the real
    /// login: the static token is read on every fetch, and a defaulted file
    /// store here would go live the day a token is saved.
    public init(
        credentials: ClaudeCredentialStore,
        staticToken: any ClaudeStaticTokenStore,
        session: URLSession = .shared
    ) {
        self.credentials = credentials
        self.staticToken = staticToken
        self.session = session
    }

    public func fetch() async throws -> ClaudeUsageSnapshot {
        // A pasted setup-token outranks everything: it carries no hourly
        // expiry, so the imported copy is not even consulted while one is
        // stored. Unknown shape counts as live — the endpoint arbitrates.
        // A broken token file reads as absent and falls through to the
        // import rather than blanking it.
        if let token = try? staticToken.loadToken(), !token.isEmpty {
            do {
                return try await requestUsage(token: token)
            } catch let error as ClaudeUsageError where error == .missingCredentials {
                throw ClaudeUsageError.invalidToken
            } catch let error as ClaudeUsageError where error == .unavailable {
                // A paste the endpoint won't answer — 429, outage — must not
                // brick the card while a live import sits unused. One attempt
                // with the OAuth copy before reporting unreachable. A 401
                // stays a rejection: falling back would hide "paste a fresh
                // one" behind numbers from the other credential.
                if let snapshot = await oauthFallback() {
                    return snapshot
                }
                throw error
            }
        }
        guard let creds = try credentials.loadCredentials(), !creds.accessToken.isEmpty,
              !creds.isExpired
        else {
            // No independent refresh, deliberately: refresh tokens are
            // single-use, so minting from our copy would invalidate Claude
            // Code's own and log the user out of their real tool. An expired
            // copy just reads as logged-out until a live login is found
            // again — which the resolving store usually already picked up.
            throw ClaudeUsageError.missingCredentials
        }
        do {
            return try await requestUsage(token: creds.accessToken)
        } catch let error as ClaudeUsageError where error == .missingCredentials {
            // 401: the served copy is revoked or rotated elsewhere. One
            // retry with the CLI's live login before reporting logged-out —
            // still no minting, just adopting the CLI's own fresh token.
            guard let fallback = try? credentials.loadFallbackCredentials(),
                  !fallback.accessToken.isEmpty, !fallback.isExpired,
                  fallback.accessToken != creds.accessToken
            else { throw error }
            let snapshot = try await requestUsage(token: fallback.accessToken)
            try? credentials.saveCredentials(fallback)
            return snapshot
        }
    }

    /// One attempt with the imported OAuth copy when the pasted token gets
    /// no answer. Nil when there is no live import or it fails too — the
    /// caller then reports the paste's own error. Never writes: the paste
    /// stays stored even when the import serves.
    private func oauthFallback() async -> ClaudeUsageSnapshot? {
        guard let creds = try? credentials.loadCredentials(),
              !creds.accessToken.isEmpty, !creds.isExpired
        else { return nil }
        return try? await requestUsage(token: creds.accessToken)
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
                // Revoked or rotated elsewhere — the caller retries once
                // with the CLI's live login before surfacing this.
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
    /// Last endpoint verdict, success or refusal. A refusal backs off behind
    /// the same TTL as fresh data — otherwise every panel open refetches,
    /// which sustains a rate limit indefinitely. Missing or rejected
    /// credentials and cancelled fetches record nothing, so recovery stays
    /// prompt. Display still keys off lastUpdated, so a failed fetch never
    /// reads as fresh data.
    @ObservationIgnored private var lastAttempt: Date?

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
    /// if the widget ever grows one. Explicit, so it always runs — the
    /// backoff lives in activate(), not here.
    public func refresh() async {
        do {
            let snapshot = try await source.fetch()
            guard !Task.isCancelled else { return }
            lastAttempt = Date()
            self.snapshot = snapshot
            self.lastUpdated = Date()
            self.lastError = nil
        } catch is CancellationError {
            return
        } catch let error as ClaudeUsageError {
            guard !Task.isCancelled else { return }
            // Only an endpoint verdict backs off: a refusal consumed
            // budget, while a missing or rejected credential made no useful
            // request — the next open retries those promptly, so a fresh
            // paste or import takes effect. Cancelled fetches record
            // nothing, so shutting the panel mid-fetch never suppresses the
            // reopen.
            if error == .unavailable { lastAttempt = Date() }
            self.lastError = error
        } catch {
            guard !Task.isCancelled else { return }
            lastAttempt = Date()
            self.lastError = .unavailable
        }
    }

    private var isStale: Bool {
        guard let lastAttempt else { return true }
        let elapsed = Date().timeIntervalSince(lastAttempt)
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
