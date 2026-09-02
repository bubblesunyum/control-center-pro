// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import Observation
import PsymailKit

/// One message as the mail widget draws it.
///
/// An alias rather than a struct of our own: `PsymailMessage` is already
/// psymail's cross-repository value type, published for exactly this — copying
/// it here would buy a mapping function and no insulation the alias doesn't
/// already give. If psymail renames it, this line is the one that changes.
public typealias MailMessage = PsymailMessage

// MARK: - Source

/// Where the widget's mail comes from.
///
/// The seam a test stands a fake in for: the real inbox signs into Google over
/// a loopback redirect and opens a SwiftData store, neither of which a test can
/// arrange.
@MainActor
public protocol MailInboxSource: AnyObject {
    var messages: [MailMessage] { get }
    var accountAddresses: [String] { get }
    var isLoading: Bool { get }
    var isSigningIn: Bool { get }
    var lastError: String? { get }
    var hasCredentials: Bool { get }
    var unavailableReason: String? { get }

    func freshness(neverUpdated: String) -> String
    func loadCache()
    func refreshIfStale() async
    func refresh() async
    func signIn() async
    func markSeen(_ message: MailMessage) async
    func archive(_ message: MailMessage) async
    func gmailURL(for message: MailMessage) -> URL?
}

/// The real one. `PsymailInbox` already has this shape — the conformance is
/// what names it as the boundary rather than a coincidence.
extension PsymailInbox: MailInboxSource {}

// MARK: - Adapter

/// The mail widget's model: the top of the inbox, refreshed while the panel is
/// open and left alone while it is shut.
///
/// Unlike ``ClipboardAdapter``, this one really does go quiet on `deactivate()`.
/// Mail that arrives while the panel is down is still on Gmail's server when it
/// comes back up, and psymail's on-disk cache means the next open draws
/// instantly from the last fetch — so there is nothing a background poll would
/// buy that the reopen doesn't.
@MainActor
@Observable
public final class MailAdapter {
    public private(set) var messages: [MailMessage] = []
    public private(set) var isSignedIn = false
    public private(set) var isRefreshing = false
    public private(set) var isSigningIn = false
    public private(set) var lastError: String?
    /// False until a fetch has actually finished. An empty list means nothing
    /// before then — the difference between "your inbox is clear" and "we have
    /// not looked yet", which the card would otherwise state as the first.
    public private(set) var hasLoaded = false

    /// False when the bundle carries no Google OAuth client id — a build that
    /// was assembled without `AppBundle/Secrets.plist`. Distinct from being
    /// signed out: there is nothing to sign in *with*, so the widget says so
    /// rather than offering a button that cannot work.
    public var hasCredentials: Bool { inbox.hasCredentials }

    /// Why mail cannot work at all, or nil when it can — a cache that will not
    /// open. Not the same as being signed out, and not something a Connect
    /// button would fix.
    public var unavailableReason: String? { inbox.unavailableReason }

    public var unreadCount: Int { messages.count(where: \.isUnread) }

    public func freshness(neverUpdated: String) -> String {
        inbox.freshness(neverUpdated: neverUpdated)
    }

    @ObservationIgnored private let inbox: any MailInboxSource
    @ObservationIgnored private var refresh: Task<Void, Never>?

    public convenience init() {
        self.init(inbox: PsymailInbox(limit: Self.visibleMessages))
    }

    public init(inbox: any MailInboxSource) {
        self.inbox = inbox
        read()
    }

    /// How many rows the lane card has room for. The inbox is asked for exactly
    /// this many, so a fetch that returns hundreds costs one prefix rather than
    /// a list the card then throws away.
    static let visibleMessages = 8

    // MARK: - Lifecycle

    /// Draw from cache immediately, then fetch only if the inbox has gone
    /// stale — a panel opened twice in a minute must not refetch.
    public func activate() {
        inbox.loadCache()
        read()
        guard isSignedIn else {
            // Nothing to wait for: a signed-out card must not sit on a spinner.
            hasLoaded = true
            return
        }
        refresh?.cancel()
        refresh = Task { [weak self] in
            await self?.inbox.refreshIfStale()
            guard !Task.isCancelled else { return }
            self?.hasLoaded = true
            self?.read()
        }
    }

    public func deactivate() {
        refresh?.cancel()
        refresh = nil
        isRefreshing = false
    }

    // MARK: - Actions

    public func refreshNow() {
        guard isSignedIn, !isRefreshing else { return }
        isRefreshing = true
        refresh?.cancel()
        refresh = Task { [weak self] in
            await self?.inbox.refresh()
            guard !Task.isCancelled else { return }
            self?.isRefreshing = false
            self?.hasLoaded = true
            self?.read()
        }
    }

    public func signIn() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        await inbox.signIn()
        isSigningIn = false
        read()
    }

    public func markSeen(_ message: MailMessage) async {
        await inbox.markSeen(message)
        read()
    }

    public func archive(_ message: MailMessage) async {
        await inbox.archive(message)
        read()
    }

    public func gmailURL(for message: MailMessage) -> URL? {
        inbox.gmailURL(for: message)
    }

    private func read() {
        messages = inbox.messages
        isSignedIn = !inbox.accountAddresses.isEmpty
        isSigningIn = inbox.isSigningIn
        lastError = inbox.lastError
        if !inbox.isLoading { isRefreshing = false }
    }
}
