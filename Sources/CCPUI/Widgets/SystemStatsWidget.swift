// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// The flagship widget: CPU, memory, temperature and network graphs over the
/// Metrics and SystemMonitor samplers.
///
/// Replaces the placeholder that stood in while the shell was being built.
/// The `activate`/`deactivate` lifecycle is what keeps a shut panel at ~0%
/// idle CPU — the adapter behind this view does nothing until it is told to.
@MainActor
public final class SystemStatsWidget: CCPWidget {
    public static let descriptor = WidgetDescriptor(
        id: "system-stats",
        title: "System",
        symbolName: "chart.bar.xaxis",
        size: .tall
    )

    private let adapter: SystemStatsAdapter

    public init() {
        self.adapter = SystemStatsAdapter()
    }

    /// Test seam: a widget backed by a fake source.
    init(source: SystemStatsSource) {
        self.adapter = SystemStatsAdapter(source: source)
    }

    public func makeView() -> some View {
        SystemStatsContent(adapter: adapter)
    }

    public func activate() { adapter.activate() }
    public func deactivate() { adapter.deactivate() }
}

// MARK: - Content

private struct SystemStatsContent: View {
    @Bindable var adapter: SystemStatsAdapter

    var body: some View {
        WidgetCard(SystemStatsWidget.descriptor) {
            VStack(alignment: .leading, spacing: Space.one) {
                cpuRow
                memoryRow
                networkRow
                temperatureRow
            }
        }
    }

    private var cpuRow: some View {
        StatRow(
            symbol: "cpu",
            title: "CPU",
            value: adapter.snapshot.cpuUsage.map { percent($0) } ?? "--",
            history: adapter.snapshot.cpuHistory,
            color: .widgetAccent,
            showsZeroBaseline: true,
            maxValue: 1
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("CPU \(adapter.snapshot.cpuUsage.map { percent($0) } ?? "unknown")")
    }

    private var memoryRow: some View {
        let snapshot = adapter.snapshot
        let used = snapshot.memoryUsed.map { Self.bytes($0) } ?? "--"
        let total = snapshot.memoryTotal.map { Self.bytes($0) } ?? "--"
        return StatRow(
            symbol: "memorychip",
            title: "Memory",
            value: snapshot.memoryUsed != nil ? "\(used) / \(total)" : "--",
            history: snapshot.memoryHistory,
            color: color(for: snapshot.memoryPressure),
            showsZeroBaseline: true,
            maxValue: 1
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Memory \(used) of \(total)")
    }

    private var networkRow: some View {
        let snapshot = adapter.snapshot
        let down = snapshot.netDownBytesPerSec.map { bytesPerSec($0) } ?? "--"
        let up = snapshot.netUpBytesPerSec.map { bytesPerSec($0) } ?? "--"
        let peak = max(snapshot.netDownHistory.max() ?? 0, snapshot.netUpHistory.max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: Space.half) {
            HStack(spacing: Space.half) {
                Image(systemName: "network")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text("Network")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("↓\(down) ↑\(up)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            ZStack {
                if snapshot.netDownHistory.count >= 2 {
                    Sparkline(values: snapshot.netDownHistory, color: .widgetAccent, maxValue: peak, showsZeroBaseline: true)
                }
                if snapshot.netUpHistory.count >= 2 {
                    Sparkline(values: snapshot.netUpHistory, color: .green, maxValue: peak, fillOpacity: 0.08)
                }
                if snapshot.netDownHistory.count < 2 && snapshot.netUpHistory.count < 2 {
                    RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
                        .fill(Color.controlFill)
                        .overlay(
                            Text("Measuring…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(height: Layout.sparklineHeight)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Network download \(down) upload \(up)")
    }

    private var temperatureRow: some View {
        let snapshot = adapter.snapshot
        let cpuTemp = snapshot.cpuTemperature.map { temperature($0) } ?? "--"
        let gpuTemp = snapshot.gpuTemperature.map { temperature($0) } ?? "--"
        return HStack(spacing: Space.one) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CPU")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(cpuTemp)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            } icon: {
                Image(systemName: "thermometer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GPU")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(gpuTemp)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            } icon: {
                Image(systemName: "thermometer.sun")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Temperatures CPU \(cpuTemp) GPU \(gpuTemp)")
    }

    // MARK: - Formatting

    private func percent(_ fraction: Double) -> String {
        "\(Int((max(0, min(1, fraction)) * 100).rounded()))%"
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return f
    }()

    private static func bytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(value))
    }

    private func bytesPerSec(_ value: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var v = max(0, value)
        var idx = 0
        while v >= 1024, idx < units.count - 1 {
            v /= 1024
            idx += 1
        }
        if idx == 0 { return "\(Int(v.rounded())) \(units[idx])" }
        return v < 10 ? String(format: "%.1f %@", v, units[idx]) : String(format: "%.0f %@", v, units[idx])
    }

    private func temperature(_ celsius: Double) -> String {
        String(format: "%.0f °C", celsius)
    }

    private func color(for pressure: SystemMemoryPressure) -> Color {
        switch pressure {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        case .unknown: return .widgetAccent
        }
    }
}

private struct StatRow: View {
    let symbol: String
    let title: String
    let value: String
    let history: [Double]
    let color: Color
    var showsZeroBaseline = false
    var maxValue: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Space.half) {
            HStack(spacing: Space.half) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            ZStack {
                if history.count >= 2 {
                    Sparkline(values: history, color: color, maxValue: maxValue, showsZeroBaseline: showsZeroBaseline)
                } else {
                    RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
                        .fill(Color.controlFill)
                        .overlay(
                            Text(history.isEmpty ? "Measuring…" : "Collecting…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(height: Layout.sparklineHeight)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous))
        }
    }
}
