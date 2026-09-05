// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import Observation

/// What the Settings row shows. The stored URL itself is never exposed — it
/// is the credential, and a field that echoes it leaks it onto the screen.
public enum CraftConnectionStatus: Equatable, Sendable {
    case notConfigured
    case invalidURL
    case checking(spaceName: String?)
    case connected(spaceName: String)
    case unreachable
}

/// Owns the Craft connection URL in the Keychain and verifies it with
/// `GET /connection`. The one place that knows both the credential store and
/// the client; the sync work later asks it for a verified base URL.
@MainActor
@Observable
public final class CraftConnectionModel {
    /// Entry only. Never refilled from the Keychain — once saved, the field
    /// clears and the URL is not shown again.
    public var urlText: String = ""
    public private(set) var status: CraftConnectionStatus = .notConfigured
    /// Cached so view bodies do not IPC into the Keychain on every
    /// evaluation. Updated at the four sites that touch the store below.
    public private(set) var isConfigured = false

    @ObservationIgnored private let store: any CraftCredentialStore
    @ObservationIgnored private let transport: (any CraftTransport)?
    @ObservationIgnored private var checkTask: Task<Void, Never>?

    public convenience init() {
        self.init(store: KeychainCraftCredentialStore(), transport: nil)
    }

    /// A nil transport asks `CraftClient` for its default session, which is
    /// the one place the request timeout lives.
    public init(store: any CraftCredentialStore, transport: (any CraftTransport)? = nil) {
        self.store = store
        self.transport = transport
        isConfigured = (try? store.loadConnectionURL()) != nil
    }

    /// The verified base URL for the sync work. Nil unless a URL is stored;
    /// verification itself happens through `verify()`.
    public var baseURL: URL? {
        try? store.loadConnectionURL()
    }

    /// One-line rendering of the status. Lives on the model rather than in
    /// the Settings view because the widget header (ccp-2zi.7) will need the
    /// same wording for the same states.
    public var statusText: String {
        switch status {
        case .notConfigured, .invalidURL:
            "Not connected"
        case .checking:
            "Checking…"
        case .connected(let spaceName):
            "Connected to \(spaceName)"
        case .unreachable:
            "Unreachable"
        }
    }

    /// Validate the entered text, store it, and verify it. A Keychain failure
    /// keeps the entered text in the field — the user should not have to
    /// fetch the URL from Craft a second time — and reports `.unreachable`,
    /// which the unconfigured branch of the UI reads as a save failure.
    public func save() {
        checkTask?.cancel()
        guard let url = CraftClient.baseURL(from: urlText) else {
            status = .invalidURL
            return
        }
        do {
            try store.saveConnectionURL(url)
        } catch {
            status = .unreachable
            return
        }
        urlText = ""
        isConfigured = true
        verify()
    }

    /// Forgets the credential. Reports success only when the item is actually
    /// gone — the UI must never claim a credential is destroyed while it is
    /// still in the Keychain.
    public func forget() {
        checkTask?.cancel()
        do {
            try store.deleteConnectionURL()
        } catch {
            status = .unreachable
            return
        }
        isConfigured = false
        status = .notConfigured
    }

    /// One `GET /connection`, safe to call on appear: a single request in a
    /// window the user opened on purpose. The check runs to completion even
    /// if the window closes first, which is harmless — the model outlives the
    /// window, and the status is current when it reopens. A Keychain read
    /// failure keeps the configured state and reports `.unreachable`: only a
    /// confirmed absence resets to `.notConfigured`.
    public func verify() {
        checkTask?.cancel()
        let url: URL?
        do {
            url = try store.loadConnectionURL()
        } catch {
            status = .unreachable
            return
        }
        guard let url else {
            isConfigured = false
            status = .notConfigured
            return
        }
        isConfigured = true
        let previousName: String? = if case .connected(let name) = status { name } else { nil }
        status = .checking(spaceName: previousName)
        let client = CraftClient(baseURL: url, transport: transport)
        checkTask = Task { @MainActor [weak self] in
            let space = try? await client.checkConnection()
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if let space {
                self.status = .connected(spaceName: space.name)
            } else {
                self.status = .unreachable
            }
        }
    }
}
