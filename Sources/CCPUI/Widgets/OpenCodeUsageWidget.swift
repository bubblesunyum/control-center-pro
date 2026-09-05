// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import SwiftUI

/// Go plan quota: 5-hour, weekly and monthly usage against the same endpoint
/// the dashboard reads, with reset countdowns ticking locally off `resetsAt`.
///
/// Percentages and resets are server-side — the local session DB provably
/// cannot reconstruct the rolling window — so a failed fetch degrades to an
/// inline state, never an empty card or a blocked panel.
@MainActor
public final class OpenCodeUsageWidget: CCPWidget {
    public static let descriptor = WidgetDescriptor(
        id: "opencode-usage",
        title: "OpenCode",
        symbolName: "terminal",
        size: .compact
    )

    static let workspaceURL = URL(
        string: "https://opencode.ai/workspace/wrk_01M1QG8Q7R6EVADZ33HGZHTP6H/go")!

    private let adapter: OpenCodeUsageAdapter

    public init() {
        self.adapter = OpenCodeUsageAdapter()
    }

    /// Test seam: a widget backed by a fake source.
    init(source: OpenCodeUsageSource) {
        self.adapter = OpenCodeUsageAdapter(source: source)
    }

    public func makeView() -> some View {
        OpenCodeUsageContent(adapter: adapter)
    }

    public func activate() { adapter.activate() }
    public func deactivate() { adapter.deactivate() }
}

// MARK: - Content

private struct OpenCodeUsageContent: View {
    @Bindable var adapter: OpenCodeUsageAdapter

    var body: some View {
        WidgetCard(OpenCodeUsageWidget.descriptor, accessory: {
            HeaderIconButton(systemImage: "arrow.up.forward", label: "Open usage in OpenCode") {
                NSWorkspace.shared.open(OpenCodeUsageWidget.workspaceURL)
            }
        }) {
            // The countdowns tick off the adapter's 30s ticker, which lives
            // and dies with activate()/deactivate() — the hosting graph is
            // never torn down, so a view-owned timer would tick while shut.
            VStack(alignment: .leading, spacing: Space.one) {
                if adapter.lastUpdated == nil, let error = adapter.lastError {
                    errorRow(error)
                } else if adapter.lastUpdated == nil {
                    Text("Loading…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    windowRow(title: "5 hours", window: adapter.snapshot.rolling, now: adapter.now)
                    windowRow(title: "Weekly", window: adapter.snapshot.weekly, now: adapter.now)
                    windowRow(title: "Monthly", window: adapter.snapshot.monthly, now: adapter.now)
                    if adapter.lastError != nil {
                        Text("Offline — showing last fetch")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.bottom, Space.half)
        }
    }

    private func windowRow(title: String, window: OpenCodeUsageWindow?, now: Date) -> some View {
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
                Text(OpenCodeUsageWidget.percentText(window?.percent))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            UsageBar(fraction: (window?.percent ?? 0) / 100)
            HStack {
                Spacer()
                Text(OpenCodeUsageWidget.resetText(until: window?.resetsAt, now: now))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(OpenCodeUsageWidget.percentText(window?.percent)), \(OpenCodeUsageWidget.resetText(until: window?.resetsAt, now: now))")
    }

    private func errorRow(_ error: OpenCodeUsageError) -> some View {
        Text(error == .missingCredentials
            ? "Connect Go with /connect in OpenCode"
            : "Couldn't load usage")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(error == .missingCredentials
                ? "OpenCode Go not connected"
                : "OpenCode usage unavailable")
    }
}

// MARK: - Formatting

extension OpenCodeUsageWidget {
    /// Single-decimal precision: the endpoint sends ints today, floats tomorrow.
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
            return "resets in \(max(minutes, 1))m"
        case 60..<(48 * 60):
            return "resets in \(minutes / 60)h \(minutes % 60)m"
        default:
            return "resets in \(minutes / (24 * 60))d \((minutes % (24 * 60)) / 60)h"
        }
    }
}
