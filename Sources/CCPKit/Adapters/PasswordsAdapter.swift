// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import Foundation
import Observation
import OSLog
import Security

/// What saving a login came to. The password itself never appears here.
public enum PasswordsSaveError: Error, Equatable, Sendable {
    case emptySite
    case emptyUsername
    case emptyPassword
    /// Saved, but only in this Mac's file keychain: the build couldn't reach
    /// the syncing keychain (see below).
    case savedLocalOnly
    case keychain(OSStatus)
}

private extension PasswordsSaveError {
    var status: OSStatus? {
        if case .keychain(let status) = self { return status }
        return nil
    }
}

/// A site as the keychain identifies it: bare host plus the scheme and port
/// the user actually typed. Protocol and port are part of an
/// internet-password item's identity — an `http` router page saved as `https`
/// coexists with the browser's own entry instead of updating it — so they
/// travel with the server rather than being re-derived at each call-site.
public struct PasswordSite: Equatable, Sendable {
    /// `kSecAttrProtocolHTTPS` unless the user typed `http://`.
    let scheme: String
    let server: String
    /// Explicit and non-default only: `https://example.com:443` stores no
    /// port, like the browser's own entry.
    let port: Int?

    /// A bare host from whatever the user typed: scheme, path and case shed,
    /// so `https://Example.com/login` and `example.com` save onto one item.
    /// Nil when nothing parsed as a host — a bare scheme is not a site, and
    /// must not become a junk item in the user's keychain.
    public static func parse(_ site: String) -> PasswordSite? {
        let text = site.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasScheme = text.contains("://")
        guard let url = URL(string: hasScheme ? text : "https://\(text)"),
              var host = url.host, !host.isEmpty
        else { return nil }
        host = host.lowercased().trimmingCharacters(in: .init(charactersIn: "."))
        guard !host.isEmpty else { return nil }
        let isHTTP = url.scheme?.lowercased() == "http"
        let scheme: String = isHTTP ? kSecAttrProtocolHTTP as String : kSecAttrProtocolHTTPS as String
        let defaultPort = isHTTP ? 80 : 443
        let port = url.port.flatMap { $0 == defaultPort ? nil : $0 }
        return PasswordSite(scheme: scheme, server: host, port: port)
    }
}

/// The seam a test stands a fake in for: touching the login keychain is not
/// something a test should do.
public protocol PasswordsStore: AnyObject, Sendable {
    func save(site: PasswordSite, account: String, password: String) throws
}

/// The real one: one Internet-password item per site + username, marked
/// synchronizable so it syncs over iCloud Keychain and surfaces in
/// Passwords.app. Scoped to logins saved through CCP — there is no API for
/// reading anything else in Passwords, which is the point of Passwords.
///
/// The syncing keychain is entitlement-gated: ad-hoc and locally-signed
/// builds carry no keychain access group, so securityd refuses them with
/// `errSecMissingEntitlement`. Rather than failing outright there, the save
/// falls back to the file keychain — on this Mac only, no sync — and says so.
public final class KeychainPasswordsStore: PasswordsStore {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.controlcenterpro.ControlCenterPro",
        category: "passwords")

    /// Scripted SecItem entry points. The defaults talk to the real keychain;
    /// tests script statuses to drive the fallback without touching it.
    private let addItem: @Sendable ([String: Any]) -> OSStatus
    private let updateItem: @Sendable ([String: Any], [String: Any]) -> OSStatus

    public init() {
        self.addItem = { SecItemAdd($0 as CFDictionary, nil) }
        self.updateItem = { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) }
    }

    init(addItem: @Sendable @escaping ([String: Any]) -> OSStatus,
         updateItem: @Sendable @escaping ([String: Any], [String: Any]) -> OSStatus) {
        self.addItem = addItem
        self.updateItem = updateItem
    }

    public func save(site: PasswordSite, account: String, password: String) throws {
        do {
            try save(site: site, account: account, password: password, syncable: true)
        } catch let error as PasswordsSaveError where error.status == errSecMissingEntitlement {
            Self.log.info("syncable save refused (\(error.status ?? 0), this build can't reach the syncing keychain); keeping the login on this Mac")
            try save(site: site, account: account, password: password, syncable: false)
            throw PasswordsSaveError.savedLocalOnly
        }
    }

    private func save(site: PasswordSite, account: String, password: String, syncable: Bool) throws {
        let status = addItem(
            PasswordsAdapter.addQuery(site: site, account: account, password: password, syncable: syncable))
        if status == errSecDuplicateItem {
            let updateStatus = updateItem(
                PasswordsAdapter.matchQuery(site: site, account: account, syncable: syncable),
                [kSecValueData as String: Data(password.utf8)])
            guard updateStatus == errSecSuccess else {
                throw PasswordsSaveError.keychain(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw PasswordsSaveError.keychain(status)
        }
    }
}

/// The seam a test stands a fake in for: bringing Passwords forward is not
/// something a test should do.
public protocol PasswordsLauncher: AnyObject, Sendable {
    /// False when Passwords is missing or restricted on this Mac.
    func openPasswords() -> Bool
}

/// The real one. The bundle id lives here so CCPUI never names it.
public final class LivePasswordsLauncher: PasswordsLauncher {
    public init() {}

    public func openPasswords() -> Bool {
        guard let url = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: PasswordsAdapter.passwordsBundleID)
        else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}

/// The Passwords widget's model: validates a login, saves it to the login
/// keychain where Passwords.app picks it up, generates strong passwords, and
/// brings Passwords forward to verify.
@MainActor
@Observable
public final class PasswordsAdapter {
    nonisolated public static let passwordsBundleID = "com.apple.Passwords"

    /// What the widget shows after a save tap. The password never appears.
    public var notice: String?

    @ObservationIgnored private let store: any PasswordsStore
    @ObservationIgnored private let launcher: any PasswordsLauncher

    public init() {
        self.store = KeychainPasswordsStore()
        self.launcher = LivePasswordsLauncher()
    }

    /// Test seam: a widget backed by fakes.
    init(store: any PasswordsStore, launcher: any PasswordsLauncher) {
        self.store = store
        self.launcher = launcher
    }

    /// Validate, save, and report. Returns true on success; the notice always
    /// says what happened without repeating the secret.
    ///
    /// Async with the keychain work off the main actor: the calls are
    /// synchronous XPC to securityd and can stall on a locked keychain, which
    /// must not freeze the panel's 100ms open budget.
    @discardableResult
    public func save(site: String, username: String, password: String) async -> Bool {
        if let error = Self.validate(site: site, username: username, password: password) {
            notice = error.message
            return false
        }
        // Validated above, so this parses; the guard is the belt.
        guard let parsed = PasswordSite.parse(site) else {
            notice = PasswordsSaveError.emptySite.message
            return false
        }
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await Task.detached(priority: .userInitiated) { [store] in
                try store.save(site: parsed, account: account, password: password)
            }.value
            notice = "Saved for \(parsed.server) — check Passwords to verify."
            return true
        } catch PasswordsSaveError.savedLocalOnly {
            notice = "Saved \(parsed.server) on this Mac only — iCloud sync needs a team-signed build."
            return true
        } catch let error as PasswordsSaveError {
            notice = error.message
            return false
        } catch {
            notice = "Couldn't save that login."
            return false
        }
    }

    public func openPasswords() {
        if !launcher.openPasswords() {
            notice = "Couldn't open Passwords on this Mac."
        }
    }

    // MARK: - Pure helpers (tests read these, never the keychain)

    nonisolated public static func normalizedServer(_ site: String) -> String {
        PasswordSite.parse(site)?.server ?? ""
    }

    nonisolated public static func validate(site: String, username: String, password: String) -> PasswordsSaveError? {
        if PasswordSite.parse(site) == nil { return .emptySite }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyUsername }
        if password.isEmpty { return .emptyPassword }
        return nil
    }

    /// A strong password from the system RNG. Unambiguous alphabet — no
    /// `0O1lI` — so it survives being read back off a small card.
    nonisolated public static func generatePassword(length: Int = 20) -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789!@#$%^&*-_?")
        var bytes = [UInt8](repeating: 0, count: max(length, 1))
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return String((0..<max(length, 1)).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    // MARK: - Keychain queries

    /// Internet-password, not generic-password: only the former renders as a
    /// Login in Passwords and participates in AutoFill.
    ///
    /// `syncable: false` leaves both the sync flag and the data-protection
    /// keychain out: the item lands in the file keychain, which any build
    /// can write. No entitlement there can gate.
    nonisolated static func addQuery(site: PasswordSite, account: String, password: String, syncable: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: site.server,
            kSecAttrAccount as String: account,
            kSecAttrProtocol as String: site.scheme,
            kSecValueData as String: Data(password.utf8),
        ]
        if syncable {
            // Unset means local-only: without this the item never reaches
            // iCloud Keychain or Passwords.
            query[kSecAttrSynchronizable as String] = true
            query[kSecUseDataProtectionKeychain as String] = true
        }
        if let port = site.port {
            query[kSecAttrPort as String] = port
        }
        return query
    }

    /// Matches on identity only: matching on the new bytes finds nothing when
    /// the stored password differs, which is exactly when an update runs.
    /// `SynchronizableAny` so the update also heals a pre-existing local-only
    /// twin instead of failing against it forever.
    nonisolated static func matchQuery(site: PasswordSite, account: String, syncable: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: site.server,
            kSecAttrAccount as String: account,
            kSecAttrProtocol as String: site.scheme,
        ]
        if syncable {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            query[kSecUseDataProtectionKeychain as String] = true
        }
        if let port = site.port {
            query[kSecAttrPort as String] = port
        }
        return query
    }
}

private extension PasswordsSaveError {
    var message: String {
        switch self {
        case .emptySite: return "Enter a site first."
        case .emptyUsername: return "Enter a username first."
        case .emptyPassword: return "Enter a password, or generate one."
        case .savedLocalOnly: return "Saved on this Mac only."
        case .keychain: return "Couldn't save that login."
        }
    }
}
