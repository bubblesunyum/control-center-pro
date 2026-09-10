// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import SwiftUI

/// Agent-usage quota: OpenCode's Go plan windows and Claude's session and
/// weekly windows, each over the endpoint its own dashboard reads.
///
/// Percentages and resets are server-side — no local ledger can reconstruct
/// a rolling window — so a failed fetch degrades to an inline state per
/// provider, never an empty card or a blocked panel.
@MainActor
public final class UsageWidget: CCPWidget {
    public static let descriptor = WidgetDescriptor(
        id: "ai-usage",
        title: "AI Usage",
        symbolName: "chart.bar",
        size: .compact
    )

    static let openCodeURL = URL(
        string: "https://opencode.ai/workspace/wrk_01M1QG8Q7R6EVADZ33HGZHTP6H/go")!
    static let claudeUsageURL = URL(string: "https://claude.ai/settings/usage")!

    private let openCode: OpenCodeUsageAdapter
    private let claude: ClaudeUsageAdapter

    public init() {
        self.openCode = OpenCodeUsageAdapter()
        self.claude = ClaudeUsageAdapter()
    }

    /// Test seam: a widget backed by fake sources. The spend store stays out —
    /// a fake source's fixed percents must survive, not be refined away.
    init(openCodeSource: OpenCodeUsageSource, claudeSource: ClaudeUsageSource) {
        self.openCode = OpenCodeUsageAdapter(source: openCodeSource, spend: nil)
        self.claude = ClaudeUsageAdapter(source: claudeSource)
    }

    public func makeView() -> some View {
        UsageContent(openCode: openCode, claude: claude)
    }

    public func activate() {
        openCode.activate()
        claude.activate()
    }

    public func deactivate() {
        openCode.deactivate()
        claude.deactivate()
    }
}

// MARK: - Content

private struct UsageContent: View {
    @Bindable var openCode: OpenCodeUsageAdapter
    @Bindable var claude: ClaudeUsageAdapter

    var body: some View {
        WidgetCard(UsageWidget.descriptor) {
            // The countdowns tick off each adapter's 30s ticker, which lives
            // and dies with activate()/deactivate() — the hosting graph is
            // never torn down, so a view-owned timer would tick while shut.
            VStack(alignment: .leading, spacing: Space.three) {
                providerSection(
                    provider: .openCode,
                    lastUpdated: openCode.lastUpdated,
                    lastError: openCodeError
                ) {
                    windowRow(provider: .openCode, title: "5 hours", window: openCode.snapshot.rolling, now: openCode.now)
                    windowRow(provider: .openCode, title: "Weekly", window: openCode.snapshot.weekly, now: openCode.now)
                    windowRow(provider: .openCode, title: "Monthly", window: openCode.snapshot.monthly, now: openCode.now)
                }
                // Claude publishes no monthly limit, so the section ends here.
                providerSection(
                    provider: .claude,
                    lastUpdated: claude.lastUpdated,
                    lastError: claudeError
                ) {
                    windowRow(provider: .claude, title: "5 hours", window: claude.snapshot.rolling, now: claude.now)
                    windowRow(provider: .claude, title: "Weekly", window: claude.snapshot.weekly, now: claude.now)
                }
            }
            .padding(.bottom, Space.half)
            // The card puts 8pt between its header and this content; top up
            // to the 24pt the sections keep between each other.
            .padding(.top, Space.two)
        }
    }

    /// Erases the two adapters' error types into one section state: either
    /// half is either missing its login or unreachable, and the section only
    /// needs to know which.
    private var openCodeError: ProviderError? {
        openCode.lastError.map(ProviderError.init)
    }

    private var claudeError: ProviderError? {
        claude.lastError.map(ProviderError.init)
    }

    private func providerSection<Rows: View>(
        provider: Provider,
        lastUpdated: Date?,
        lastError: ProviderError?,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.one) {
            ProviderHeader(provider: provider)
            if lastError == .missingLogin {
                // Logged-out beats stale: rows from a dead grant read as live
                // numbers, and for Claude this is where the Import button
                // lives — including the hourly expiry after a prior success.
                errorRow(.missingLogin, provider: provider)
            } else if lastUpdated == nil, let lastError {
                errorRow(lastError, provider: provider)
            } else if lastUpdated == nil {
                Text("Loading…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                rows()
                if lastError != nil {
                    Text("Offline — showing last fetch")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func windowRow(provider: Provider, title: String, window: UsageWindow?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: Space.half) {
            HStack(spacing: Space.half) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                if window?.isRateLimited == true {
                    Text("Limited")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(UsageWidget.resetText(until: window?.resetsAt, now: now))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(UsageWidget.percentText(window?.percent))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            UsageBar(fraction: (window?.percent ?? 0) / 100)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider.title) \(title) \(UsageWidget.percentText(window?.percent)), \(UsageWidget.resetText(until: window?.resetsAt, now: now))")
    }

    @ViewBuilder
    private func errorRow(_ error: ProviderError, provider: Provider) -> some View {
        switch (provider, error) {
        case (.claude, .missingLogin):
            ClaudeImportPrompt(
                importLogin: { try ClaudeLoginImporter().importLogin() },
                refresh: { await claude.refresh() }
            )
        case (.openCode, .missingLogin):
            Text("Connect Go with /connect in OpenCode")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("OpenCode Go not connected")
        case (_, .unreachable):
            Text("Couldn't load usage")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(provider.title) usage unavailable")
        }
    }
}

/// The Claude empty state: one explicit import behind a button, with the
/// failure naming its own recovery.
private struct ClaudeImportPrompt: View {
    let importLogin: () throws -> Bool
    let refresh: () async -> Void

    @State private var issue: ImportIssue?

    var body: some View {
        // The one explicit keychain moment: a single prompt behind this
        // button copies the login into our private store, and the fetch
        // path never touches the keychain again.
        VStack(alignment: .leading, spacing: Space.half) {
            Button("Import from Claude Code") {
                Task { @MainActor in
                    do {
                        if try importLogin() {
                            issue = nil
                            await refresh()
                        } else {
                            issue = .noLogin
                        }
                    } catch {
                        issue = .saveFailed
                    }
                }
            }
            .buttonStyle(.link)
            .accessibilityLabel("Import Claude login from Claude Code")
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var caption: String {
        switch issue {
        case .noLogin:
            "No Claude login found — run claude auth login first, then import again"
        case .saveFailed:
            "Couldn't save the login — check disk space, then import again"
        case nil:
            "Requires claude auth login in a terminal first"
        }
    }
}

private enum ImportIssue {
    case noLogin
    case saveFailed
}

private enum Provider {
    case openCode
    case claude

    var title: String {
        switch self {
        case .openCode: "OpenCode"
        case .claude: "Claude"
        }
    }

    var linkLabel: String {
        switch self {
        case .openCode: "Open usage in OpenCode"
        case .claude: "Open usage in Claude"
        }
    }

    var linkURL: URL {
        switch self {
        case .openCode: UsageWidget.openCodeURL
        case .claude: UsageWidget.claudeUsageURL
        }
    }
}

private enum ProviderError {
    case missingLogin
    case unreachable

    init(_ error: OpenCodeUsageError) {
        self = error == .missingCredentials ? .missingLogin : .unreachable
    }

    init(_ error: ClaudeUsageError) {
        self = error == .missingCredentials ? .missingLogin : .unreachable
    }
}

/// A provider's nameplate: small-caps label with a chevron, the whole thing
/// opening that provider's own usage page.
private struct ProviderHeader: View {
    let provider: Provider

    var body: some View {
        Button {
            NSWorkspace.shared.open(provider.linkURL)
        } label: {
            HStack(spacing: Space.half) {
                Text(provider.title.uppercased())
                    .sectionCaps()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(provider.linkLabel)
        .accessibilityAddTraits(.isLink)
    }
}

// MARK: - Formatting

extension UsageWidget {
    /// Single-decimal precision: the endpoints send ints today, floats tomorrow.
    static func percentText(_ percent: Double?) -> String {
        guard let percent else { return "--" }
        return String(format: "%.1f%%", percent)
    }

    /// Coarse buckets — the readout ticks every 30s, so seconds would lie.
    static func resetText(until date: Date?, now: Date) -> String {
        guard let date else { return "--" }
        let remaining = date.timeIntervalSince(now)
        guard remaining > 0 else { return "resetting…" }
        let minutes = Int(remaining / 60)
        switch minutes {
        case 0..<60:
            return "\(max(minutes, 1))m"
        case 60..<(48 * 60):
            return "\(minutes / 60)h \(minutes % 60)m"
        default:
            return "\(minutes / (24 * 60))d \((minutes % (24 * 60)) / 60)h"
        }
    }
}
