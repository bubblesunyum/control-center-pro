// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import Security

/// Where the Craft connection URL lives.
///
/// Craft Connect has no auth header — the connection URL itself is the secret
/// — so it lives in one owner-only file under Application Support, never in
/// UserDefaults, settings.json, logs, or a bead. The protocol is the seam
/// tests and previews use; the app uses the file implementation.
///
/// Loading throws only on a store failure other than "no such item", so
/// callers can tell a missing credential apart from an unreadable store.
public protocol CraftCredentialStore: Sendable {
    func loadConnectionURL() throws -> URL?
    func saveConnectionURL(_ url: URL) throws
    func deleteConnectionURL() throws
}

public struct CraftKeychainError: Error, Equatable {
    public let status: OSStatus
}

public enum FileCraftCredentialError: Error {
    case unwritten
}

/// Generic-password item holding the connection URL as UTF-8 bytes.
public struct KeychainCraftCredentialStore: CraftCredentialStore {
    private let service: String
    private let account: String

    public init(service: String = "com.controlcenterpro.craft-connection",
                account: String = "connection-url") {
        self.service = service
        self.account = account
    }

    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func loadConnectionURL() throws -> URL? {
        var query = query()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CraftKeychainError(status: status)
        }
        return URL(string: String(decoding: data, as: UTF8.self))
    }

    /// Reads without ever prompting. A normal read on a build the Keychain
    /// does not trust yet shows the Allow dialog; with
    /// `kSecUseAuthenticationUIFail` it instead fails fast with
    /// `errSecInteractionNotAllowed`, which reads here as "nothing to
    /// migrate". Only the one-time migration off the Keychain uses this.
    public func loadWithoutPrompt() throws -> URL? {
        var query = query()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound || status == errSecInteractionNotAllowed { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CraftKeychainError(status: status)
        }
        return URL(string: String(decoding: data, as: UTF8.self))
    }

    public func saveConnectionURL(_ url: URL) throws {
        let data = Data(url.absoluteString.utf8)
        var addition = query()
        addition[kSecValueData as String] = data
        let status = SecItemAdd(addition as CFDictionary, nil)
        // The update matches on class/service/account only: matching on the
        // new bytes instead finds nothing when the stored URL differs.
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query() as CFDictionary,
                                             [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw CraftKeychainError(status: updateStatus)
            }
            return
        }
        guard status == errSecSuccess else { throw CraftKeychainError(status: status) }
    }

    public func deleteConnectionURL() throws {
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CraftKeychainError(status: status)
        }
    }
}

/// The connection URL as UTF-8 bytes in one owner-only file — the psymail
/// shape, not the login Keychain.
///
/// A login-Keychain item is ACL'd to the build that created it, and dev
/// builds are re-signed on every compile, so each launch arrived as a
/// stranger and macOS asked the user to vouch for it. A 0600 file in the
/// app's own container is isolated by the OS and encrypted at rest under
/// FileVault, and never prompts.
///
/// Items stored by earlier builds are picked up once, silently: the first
/// load with no file tries a prompt-free Keychain read, files what it finds,
/// and removes the item so a later Forget cannot resurrect it. A build the
/// Keychain does not trust reads back nothing instead of prompting, and the
/// user pastes the URL once in Settings.
public struct FileCraftCredentialStore: CraftCredentialStore {
    private let fileURL: URL
    private let keychain: KeychainCraftCredentialStore?
    /// - Parameter keychain: the migration source. The app leaves the
    ///   default; tests pass nil (or a uniquely-named item) so no test ever
    ///   moves the real credential.
    public init(fileURL: URL? = nil, keychain: KeychainCraftCredentialStore? = .init()) {
        self.fileURL = fileURL ?? .applicationSupport.appendingPathComponent("craft-connection-url")
        self.keychain = keychain
    }

    public func loadConnectionURL() throws -> URL? {
        do {
            let data = try Data(contentsOf: fileURL)
            // Blank bytes were never a saved credential — saves are
            // validated — so this reads as missing, and the next save
            // overwrites it. Anything else unreadable throws, so the caller
            // reports a broken store instead of an empty one.
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : URL(string: text)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return migratedURL()
        }
    }

    public func saveConnectionURL(_ url: URL) throws {
        try writeOwnerOnly(Data(url.absoluteString.utf8))
        // Only a read-back proves the bytes landed: a throw after a
        // successful write would report "nothing was stored" while the next
        // launch reads the file as configured.
        guard (try? Data(contentsOf: fileURL)) == Data(url.absoluteString.utf8) else {
            throw FileCraftCredentialError.unwritten
        }
    }

    /// Removes the file and any Keychain item earlier builds left behind.
    /// The Keychain goes first and throwing, so a failure keeps the file and
    /// the configured state with it — and a forgotten credential can never
    /// re-migrate from an orphan on the next launch. The delete runs on an
    /// explicit user action, which is the one moment a system dialog would
    /// be contextual rather than a surprise.
    public func deleteConnectionURL() throws {
        try keychain?.deleteConnectionURL()
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already gone is gone.
        }
    }

    /// Owner-only from birth, never world-readable in between. `.atomic`
    /// renames a default-mode temp file into place and chmods after, which
    /// leaves a 0644 window a crash makes permanent — so the temp file is
    /// created 0600 and renamed over the target instead. A crash mid-swap
    /// loses the credential (fail-safe: the user re-enters it) rather than
    /// exposing it.
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
                throw FileCraftCredentialError.unwritten
            }
            try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    private func migratedURL() -> URL? {
        guard let keychain else { return nil }
        let migrated: URL? = try? keychain.loadWithoutPrompt()
        guard let url = migrated else { return nil }
        do {
            try saveConnectionURL(url)
        } catch {
            // The session still works off this return; the next launch
            // retries the migration while the Keychain item survives.
            return url
        }
        // The silent read above just proved this build is trusted, so this
        // delete does not prompt. If it still fails the orphaned item is
        // never read again — the file now exists, and loads stop here.
        try? keychain.deleteConnectionURL()
        return url
    }
}

/// In-memory stand-in for tests and previews. Never ships in the app.
/// Unchecked Sendable because tests confine it to the main actor; it holds
/// no locking and must not be shared across threads anywhere else.
public final class InMemoryCraftCredentialStore: CraftCredentialStore, @unchecked Sendable {
    private var url: URL?

    public init(url: URL? = nil) {
        self.url = url
    }

    public func loadConnectionURL() throws -> URL? { url }

    public func saveConnectionURL(_ url: URL) throws {
        self.url = url
    }

    public func deleteConnectionURL() throws {
        url = nil
    }
}
