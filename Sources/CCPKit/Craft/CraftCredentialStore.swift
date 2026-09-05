// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import Security

/// Where the Craft connection URL lives.
///
/// Craft Connect has no auth header — the connection URL itself is the secret
/// — so it goes in the Keychain, never in UserDefaults, settings.json, logs,
/// or a bead. The protocol is the seam tests and previews use; the app uses
/// the Keychain implementation.
///
/// Loading throws only on a Keychain failure other than "no such item", so
/// callers can tell a missing credential apart from a locked Keychain.
public protocol CraftCredentialStore: Sendable {
    func loadConnectionURL() throws -> URL?
    func saveConnectionURL(_ url: URL) throws
    func deleteConnectionURL() throws
}

public struct CraftKeychainError: Error, Equatable {
    public let status: OSStatus
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
