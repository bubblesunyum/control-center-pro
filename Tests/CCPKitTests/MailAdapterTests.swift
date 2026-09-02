// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import XCTest

@MainActor
final class MailAdapterTests: XCTestCase {
    // MARK: - Reporting

    func testReportsMessagesFromInbox() {
        let message = fakeMailMessage()
        let adapter = MailAdapter(inbox: FakeMailInbox(messages: [message]))
        XCTAssertEqual(adapter.messages, [message])
    }

    func testUnreadCountCountsOnlyUnread() {
        let inbox = FakeMailInbox(messages: [
            fakeMailMessage(id: "1", isUnread: true),
            fakeMailMessage(id: "2", isUnread: false),
            fakeMailMessage(id: "3", isUnread: true),
        ])
        XCTAssertEqual(MailAdapter(inbox: inbox).unreadCount, 2)
    }

    func testSignedOutWhenNoAccounts() {
        let adapter = MailAdapter(inbox: FakeMailInbox(accountAddresses: []))
        XCTAssertFalse(adapter.isSignedIn)
    }

    // MARK: - Lifecycle

    func testActivateDrawsFromCacheBeforeFetching() {
        let inbox = FakeMailInbox()
        let adapter = MailAdapter(inbox: inbox)
        inbox.messages = [fakeMailMessage()]

        adapter.activate()

        XCTAssertEqual(inbox.loadCacheCount, 1)
        XCTAssertEqual(adapter.messages.count, 1, "cached mail must be on screen without waiting on the network")
    }

    func testActivateRefreshesOnlyWhenStale() async {
        let inbox = FakeMailInbox()
        let adapter = MailAdapter(inbox: inbox)
        adapter.activate()

        let asked = await becomesTrue { inbox.refreshIfStaleCount == 1 }
        XCTAssertTrue(asked, "open must ask, and let the inbox decide whether it is stale")
        XCTAssertEqual(inbox.refreshCount, 0, "opening the panel must never force an unconditional fetch")
    }

    func testActivateSignedOutDoesNotFetch() async {
        let inbox = FakeMailInbox(accountAddresses: [])
        MailAdapter(inbox: inbox).activate()

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(inbox.refreshIfStaleCount, 0, "nothing to fetch without an account")
    }

    /// The panel shutting is the whole point of the lifecycle: mail is the one
    /// widget with a network call attached, and leaving it running would be the
    /// idle cost the panel exists to avoid.
    func testDeactivateCancelsInFlightRefresh() async {
        let inbox = FakeMailInbox()
        inbox.refreshDelay = .milliseconds(200)
        let adapter = MailAdapter(inbox: inbox)

        adapter.activate()
        adapter.deactivate()
        inbox.messages = [fakeMailMessage()]

        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(adapter.messages.isEmpty, "a cancelled refresh still published its result")
        XCTAssertFalse(adapter.hasLoaded, "a cancelled refresh must not count as the first load")
    }

    func testRefreshNowIgnoresASecondTapWhileRunning() async {
        let inbox = FakeMailInbox()
        inbox.refreshDelay = .milliseconds(100)
        let adapter = MailAdapter(inbox: inbox)

        adapter.refreshNow()
        adapter.refreshNow()

        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(inbox.refreshCount, 1, "double-tapping refresh fired two fetches")
    }

    /// The bug this guards: an empty cache and a fetch in flight rendered
    /// "Inbox is clear", which is a claim about the user's mail made before
    /// anyone had looked.
    func testEmptyInboxIsNotReportedClearBeforeTheFirstFetchFinishes() async {
        let inbox = FakeMailInbox(messages: [])
        inbox.refreshDelay = .milliseconds(150)
        let adapter = MailAdapter(inbox: inbox)

        adapter.activate()
        XCTAssertFalse(adapter.hasLoaded, "an empty list means nothing until a fetch has finished")

        let loaded = await becomesTrue { adapter.hasLoaded }
        XCTAssertTrue(loaded, "the first fetch never marked itself done")
    }

    func testSignedOutDoesNotWaitOnAFetchItWillNeverMake() {
        let adapter = MailAdapter(inbox: FakeMailInbox(accountAddresses: []))
        adapter.activate()
        XCTAssertTrue(adapter.hasLoaded, "a signed-out card would sit on a spinner forever")
    }

    func testUnavailableCacheIsReportedRatherThanCrashing() {
        let inbox = FakeMailInbox()
        inbox.unavailableReason = "The message cache could not be opened."
        let adapter = MailAdapter(inbox: inbox)
        XCTAssertEqual(adapter.unavailableReason, "The message cache could not be opened.")
    }

    // MARK: - Accounts

    func testSignInPublishesTheNewAccount() async {
        let inbox = FakeMailInbox(accountAddresses: [])
        inbox.signInAddsAccount = "someone@example.com"
        let adapter = MailAdapter(inbox: inbox)

        await adapter.signIn()

        XCTAssertTrue(adapter.isSignedIn)
        XCTAssertNil(adapter.lastError)
    }

    func testFailedSignInSurfacesItsError() async {
        let inbox = FakeMailInbox(accountAddresses: [])
        inbox.signInError = "the browser never came back"
        let adapter = MailAdapter(inbox: inbox)

        await adapter.signIn()

        XCTAssertFalse(adapter.isSignedIn)
        XCTAssertEqual(adapter.lastError, "the browser never came back")
    }

    // MARK: - Actions

    func testMarkSeenRereadsTheInbox() async {
        let unread = fakeMailMessage(isUnread: true)
        let inbox = FakeMailInbox(messages: [unread])
        let adapter = MailAdapter(inbox: inbox)

        await adapter.markSeen(unread)

        XCTAssertEqual(inbox.markedSeen, [unread.id])
        XCTAssertEqual(adapter.unreadCount, 0, "the row stayed bold after being read")
    }
}

// MARK: - Fixtures

func fakeMailMessage(
    id: String = "m1",
    sender: String = "Ada Lovelace",
    subject: String = "Notes on the Engine",
    date: Date = Date(timeIntervalSince1970: 1_700_000_000),
    isUnread: Bool = true,
    threadCount: Int = 1
) -> MailMessage {
    MailMessage(
        id: id,
        accountAddress: "reader@example.com",
        sender: sender,
        senderAddress: "ada@example.com",
        subject: subject,
        snippet: "…",
        date: date,
        isUnread: isUnread,
        threadCount: threadCount
    )
}

/// Stands in for `PsymailInbox`: no Google sign-in, no SwiftData store, and
/// every call counted so the lifecycle can be asserted rather than inferred.
@MainActor
final class FakeMailInbox: MailInboxSource {
    var messages: [MailMessage]
    var accountAddresses: [String]
    var isLoading = false
    var isSigningIn = false
    var lastError: String?
    var hasCredentials = true
    var unavailableReason: String?

    var loadCacheCount = 0
    var refreshCount = 0
    var refreshIfStaleCount = 0
    var markedSeen: [String] = []
    var archived: [String] = []

    /// How long a fetch takes, so a test can cancel one mid-flight.
    var refreshDelay: Duration = .zero
    var signInAddsAccount: String?
    var signInError: String?

    init(messages: [MailMessage] = [], accountAddresses: [String] = ["reader@example.com"]) {
        self.messages = messages
        self.accountAddresses = accountAddresses
    }

    func freshness(neverUpdated: String) -> String { neverUpdated }

    func loadCache() { loadCacheCount += 1 }

    func refreshIfStale() async {
        refreshIfStaleCount += 1
        await fetch()
    }

    func refresh() async {
        refreshCount += 1
        await fetch()
    }

    func signIn() async {
        if let signInError {
            lastError = signInError
            return
        }
        lastError = nil
        if let address = signInAddsAccount { accountAddresses.append(address) }
    }

    func markSeen(_ message: MailMessage) async {
        markedSeen.append(message.id)
        messages = messages.map {
            guard $0.id == message.id else { return $0 }
            return MailMessage(
                id: $0.id,
                accountAddress: $0.accountAddress,
                sender: $0.sender,
                senderAddress: $0.senderAddress,
                subject: $0.subject,
                snippet: $0.snippet,
                date: $0.date,
                isUnread: false,
                threadCount: $0.threadCount
            )
        }
    }

    func archive(_ message: MailMessage) async {
        archived.append(message.id)
        messages.removeAll { $0.id == message.id }
    }

    func gmailURL(for message: MailMessage) -> URL? {
        URL(string: "https://mail.google.com/mail/#all/\(message.id)")
    }

    private func fetch() async {
        guard refreshDelay > .zero else { return }
        isLoading = true
        try? await Task.sleep(for: refreshDelay)
        isLoading = false
    }
}
