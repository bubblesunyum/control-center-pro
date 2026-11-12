// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import SwiftUI

/// Agent-usage quota: OpenCode's Go plan windows, over the endpoint its own
/// dashboard reads.
///
/// Percentages and resets are server-side — no local ledger can reconstruct
/// a rolling window — so a failed fetch degrades to an inline state, never
/// an empty card or a blocked panel.
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

    private let openCode: OpenCodeUsageAdapter

    public init() {
        self.openCode = OpenCodeUsageAdapter()
    }

    /// Test seam: a widget backed by a fake source.
    init(openCodeSource: OpenCodeUsageSource) {
        self.openCode = OpenCodeUsageAdapter(source: openCodeSource)
    }

    public func makeView() -> some View {
        UsageContent(openCode: openCode)
    }

    public func activate() {
        openCode.activate()
    }

    public func deactivate() {
        openCode.deactivate()
    }
}

// MARK: - Content

private struct UsageContent: View {
    @Bindable var openCode: OpenCodeUsageAdapter

    var body: some View {
        WidgetCard(UsageWidget.descriptor) {
            // The countdowns tick off the adapter's 30s ticker, which lives
            // and dies with activate()/deactivate() — the hosting graph is
            // never torn down, so a view-owned timer would tick while shut.
            providerSection(
                lastUpdated: openCode.lastUpdated,
                lastError: openCodeError
            ) {
                windowRow(title: "5 hours", window: openCode.snapshot.rolling, now: openCode.now, paceHours: 5)
                windowRow(title: "Weekly", window: openCode.snapshot.weekly, now: openCode.now, paceDays: 7)
                windowRow(title: "Monthly", window: openCode.snapshot.monthly, now: openCode.now, paceDays: 30)
            }
            .padding(.bottom, Space.half)
            // The card puts 8pt between its header and this content; 4pt more
            // keeps the sections from crowding it.
            .padding(.top, Space.half)
        }
    }

    /// Erases the adapter's error type into one section state: a missing
    /// login or an unreachable endpoint.
    private var openCodeError: ProviderError? {
        openCode.lastError.map(ProviderError.init)
    }

    private func providerSection<Rows: View>(
        lastUpdated: Date?,
        lastError: ProviderError?,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.one) {
            ProviderHeader()
            if let lastError, lastError == .missingLogin {
                // Logged-out beats stale: rows from a dead grant read as live
                // numbers.
                errorRow(lastError)
            } else if lastUpdated == nil, let lastError {
                errorRow(lastError)
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

    private func windowRow(title: String, window: UsageWindow?, now: Date, paceDays: Int? = nil, paceHours: Int? = nil) -> some View {
        // Even-pace reference, behind the main fill. Nil without a reset to
        // split — no interval, no pace.
        let pace = paceDays.flatMap {
            UsagePace.dailyFraction(now: now, resetsAt: window?.resetsAt, totalDays: $0)
        } ?? paceHours.flatMap {
            UsagePace.fraction(now: now, resetsAt: window?.resetsAt, totalHours: $0)
        }
        return VStack(alignment: .leading, spacing: Space.half) {
            HStack(spacing: Space.half) {
                Text(title)
                    .usageFont(weight: .medium)
                    .foregroundStyle(.primary)
                if window?.isRateLimited == true {
                    Text("Limited")
                        .usageFont(weight: .medium)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(UsageWidget.resetText(until: window?.resetsAt, now: now))
                    .usageFont()
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(UsageWidget.percentText(window?.percent))
                    .usageFont(weight: .semibold)
                    .monospacedDigit()
            }
            UsageBar(fraction: (window?.percent ?? 0) / 100, secondaryFraction: pace)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("OpenCode \(title) \(UsageWidget.percentText(window?.percent)), \(UsageWidget.resetText(until: window?.resetsAt, now: now))")
    }

    @ViewBuilder
    private func errorRow(_ error: ProviderError) -> some View {
        switch error {
        case .missingLogin:
            Text("Connect Go with /connect in OpenCode")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("OpenCode Go not connected")
        case .unreachable:
            Text("Couldn't load usage")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("OpenCode usage unavailable")
        }
    }
}

private enum ProviderError {
    case missingLogin
    case unreachable

    init(_ error: OpenCodeUsageError) {
        self = error == .missingCredentials ? .missingLogin : .unreachable
    }
}

/// A provider's nameplate: small-caps label with a chevron, the whole thing
/// opening that provider's own usage page.
private struct ProviderHeader: View {
    var body: some View {
        Button {
            NSWorkspace.shared.open(UsageWidget.openCodeURL)
        } label: {
            HStack(spacing: Space.half) {
                Text("OpenCode".uppercased())
                    .sectionCaps()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open usage in OpenCode")
        .accessibilityAddTraits(.isLink)
    }
}

// MARK: - Formatting

extension UsageWidget {
    /// Whole integers: the endpoints send ints, and a 30s-ticking readout
    /// has no business implying decimal precision.
    static func percentText(_ percent: Double?) -> String {
        guard let percent else { return "--" }
        return String(format: "%.0f%%", percent)
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
