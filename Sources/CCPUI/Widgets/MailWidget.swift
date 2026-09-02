// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import SwiftUI

/// The top of the inbox, in a lane.
///
/// Control Center Pro carries psymail rather than launching it: the card is a
/// glance and a way in, not psymail's mail screen shrunk to fit. Reading a
/// message opens it in Gmail, which is why there is no detail view here.
@MainActor
public final class MailWidget: CCPWidget {
    public static let descriptor = WidgetDescriptor(
        id: "mail",
        title: "Mail",
        symbolName: "tray.full",
        size: .tall
    )

    private let adapter: MailAdapter

    public init() {
        self.adapter = MailAdapter()
    }

    /// Test seam: a widget backed by a fake inbox.
    init(inbox: any MailInboxSource) {
        self.adapter = MailAdapter(inbox: inbox)
    }

    public func makeView() -> some View {
        MailContent(adapter: adapter)
    }

    public func activate() { adapter.activate() }
    public func deactivate() { adapter.deactivate() }
}

// MARK: - Content

private struct MailContent: View {
    @Bindable var adapter: MailAdapter

    var body: some View {
        WidgetCard(
            MailWidget.descriptor,
            count: adapter.unreadCount > 0 ? adapter.unreadCount : nil,
            accessory: { refreshButton }
        ) {
            VStack(alignment: .leading, spacing: Space.one) {
                state
                if adapter.isSignedIn, !adapter.messages.isEmpty {
                    footer
                }
            }
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        if adapter.isSignedIn {
            HeaderIconButton(
                systemImage: "arrow.clockwise",
                label: "Refresh mail",
                isActive: adapter.isRefreshing
            ) {
                adapter.refreshNow()
            }
            .disabled(adapter.isRefreshing)
        }
    }

    @ViewBuilder
    private var state: some View {
        if let unavailable = adapter.unavailableReason {
            MailPlaceholder(
                symbolName: "exclamationmark.triangle",
                title: "Mail is unavailable",
                message: unavailable
            )
        } else if !adapter.hasCredentials {
            MailPlaceholder(
                symbolName: "key.slash",
                title: "Mail isn't configured",
                message: "This build has no Google credentials. See AppBundle/Secrets.plist.example."
            )
        } else if !adapter.isSignedIn {
            SignedOutMail(adapter: adapter)
        } else if adapter.messages.isEmpty {
            EmptyMail(isFetching: adapter.isRefreshing || !adapter.hasLoaded)
        } else {
            messageList
        }
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.half) {
                ForEach(adapter.messages) { message in
                    MailRow(message: message, adapter: adapter)
                }
            }
            .padding(.top, Space.quarter)
        }
        .frame(maxHeight: Layout.mailListHeight)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: Space.half) {
            Text(adapter.freshness(neverUpdated: "not yet updated"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let error = adapter.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help(error)
                    .accessibilityLabel("Mail error: \(error)")
            }
        }
    }
}

// MARK: - Row

private struct MailRow: View {
    let message: MailMessage
    let adapter: MailAdapter

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: Space.half) {
                UnreadDot(isUnread: message.isUnread)
                    .padding(.top, Space.half)
                VStack(alignment: .leading, spacing: Space.quarter) {
                    HStack(spacing: Space.half) {
                        Text(message.sender)
                            .font(.caption.weight(message.isUnread ? .semibold : .regular))
                            .lineLimit(1)
                        if message.threadCount > 1 {
                            Text("\(message.threadCount)")
                                .font(.caption2.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Space.half)
                        // The sender is the only thing on this line allowed to
                        // give way: same-priority text views compress together,
                        // and a date squeezed to "2…" tells you nothing.
                        Text(message.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                        .font(.caption2)
                        .foregroundStyle(message.isUnread ? .primary : .secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, Space.one)
            .padding(.vertical, Space.half)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(isHovering ? Color.controlFill : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(message.snippet)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.isUnread ? "Unread. " : "")From \(message.sender). \(message.subject)")
        .accessibilityHint("Opens in Gmail")
        .contextMenu {
            Button("Open in Gmail", action: open)
            Button("Mark as Read") { Task { await adapter.markSeen(message) } }
                .disabled(!message.isUnread)
            Button("Archive") { Task { await adapter.archive(message) } }
        }
    }

    /// Opening is also reading it: a message left bold after you have gone and
    /// read it in Gmail is the card disagreeing with the mailbox it mirrors.
    private func open() {
        guard let url = adapter.gmailURL(for: message) else { return }
        NSWorkspace.shared.open(url)
        guard message.isUnread else { return }
        Task { await adapter.markSeen(message) }
    }
}

/// The bold dot on an unread row. Always laid out, so every row's text starts
/// on the same vertical line whether or not it is unread.
private struct UnreadDot: View {
    let isUnread: Bool

    var body: some View {
        Circle()
            .fill(isUnread ? Color.accentColor : .clear)
            .frame(width: Layout.unreadDotSize, height: Layout.unreadDotSize)
    }
}

// MARK: - States

/// What the card shows instead of mail: no credentials, no account, or an
/// empty inbox.
///
/// One view rather than three near-identical ones, and it centres itself —
/// a `.tall` card is a lot of room for two lines, and top-anchoring them
/// leaves the card looking like it failed to finish drawing.
private struct MailPlaceholder<Actions: View>: View {
    let symbolName: String
    let title: String
    let message: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Space.half) {
            Image(systemName: symbolName)
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, Space.one)
        .accessibilityElement(children: .combine)
    }
}

private extension MailPlaceholder where Actions == EmptyView {
    init(symbolName: String, title: String, message: String? = nil) {
        self.init(symbolName: symbolName, title: title, message: message) { EmptyView() }
    }
}

private struct SignedOutMail: View {
    @Bindable var adapter: MailAdapter

    var body: some View {
        MailPlaceholder(
            symbolName: "tray.full",
            title: "No account connected",
            message: "Connect Gmail to see your mail here."
        ) {
            Button("Connect") { Task { await adapter.signIn() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(adapter.isSigningIn)
                .accessibilityLabel("Connect a Gmail account")
            if let error = adapter.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// The inbox is empty, or has not been fetched yet.
private struct EmptyMail: View {
    let isFetching: Bool

    var body: some View {
        if isFetching {
            VStack(spacing: Space.half) {
                ProgressView()
                    .controlSize(.small)
                Text("Fetching mail…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            MailPlaceholder(symbolName: "checkmark.circle", title: "Inbox is clear")
        }
    }
}
