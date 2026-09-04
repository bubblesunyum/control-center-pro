// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import Darwin
import SwiftUI

/// The flagship widget: CPU, GPU, Memory and Battery with live graphs,
/// per-app breakdowns and ¾-circle temperature gauges.
///
/// This is a CCP port of vorssaint's `SystemSection` (temperatures +
/// hardware usage + memory + uptime) re-expressed as a glass card inside
/// a CCP lane. The 13 deltas from upstream are marked in-code:
///
/// (1) no "Temperatures"/"Hardware usage" titles
/// (2) no "up for…" uptime row
/// (3) Battery has a chevron and expands to "apps using significant energy"
/// (4) no battery icon
/// (5) more spacing between sections
/// (6) "Swap" not "Swap used"
/// (7) graphs a bit taller
/// (8) Memory owns the chevron; its expansion shows what Pressure used to show
/// (9) Memory has a horizontal usage bar next to its title
/// (10) Pressure badge is dot-only, text on hover
/// (11) Battery graph only when charging
/// (12) distinct color per section, reused for every colored element in it
/// (13) no separate temperature section — each gauge lives inside its section
///     as a ¾-circle speedometer, with (12)'s color.

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

// MARK: - Private types

private enum SectionKind { case cpu, gpu, memory, battery }

private struct BreakdownRow: Identifiable {
    let id: Int32
    let pid: pid_t
    let name: String
    let value: Double
}

// MARK: - Content (pulled from vorssaint SystemSection, CCP-tailored)

private struct SystemStatsContent: View {
    @Bindable var adapter: SystemStatsAdapter
    @Environment(\.colorScheme) private var colorScheme

    @State private var expanded: SectionKind?
    @State private var breakdownRows: [BreakdownRow] = []
    @State private var breakdownLoading = false
    @State private var lastRefresh = Date.distantPast
    private let breakdownLimit = 6

    var body: some View {
        WidgetCard(SystemStatsWidget.descriptor, accessory: {
            ActivityMonitorButton()
        }) {
            // (5) more spacing between sections — upstream uses 10, we use 16
            // (new tweak 1) separators removed, spacing handles division
            VStack(alignment: .leading, spacing: Space.two) {
                cpuSection
                gpuSection
                memorySection
                if adapter.snapshot.batteryHasBattery {
                    batterySection
                }
            }
            .animation(.easeInOut(duration: 0.2), value: expanded)
            // (new tweak 7) tiny extra padding at bottom of widget
            .padding(.bottom, Space.half)
        }
        .onChange(of: adapter.snapshot) { _, _ in
            // Refresh breakdown at most every 4s while expanded, like upstream.
            guard expanded != nil, Date().timeIntervalSince(lastRefresh) > 4 else { return }
            refreshBreakdown()
        }
        .onDisappear {
            expanded = nil
            breakdownRows = []
            breakdownLoading = false
        }
    }

    // MARK: - CPU

    private var cpuSection: some View {
        sectionContainer(kind: .cpu, color: cpuColor) {
            cpuHeader
            // (7) graphs a bit taller — 34 vs upstream 22 / CCP 28
            if adapter.snapshot.cpuHistory.count >= 2 {
                Sparkline(values: adapter.snapshot.cpuHistory, color: cpuColor, maxValue: 1, showsZeroBaseline: true)
                    .frame(height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous))
            } else {
                placeholderGraph(history: adapter.snapshot.cpuHistory)
            }
            breakdownList(for: .cpu)
        }
    }

    private var cpuHeader: some View {
        Button {
            toggle(.cpu)
        } label: {
            HStack(spacing: 6) {
                chevron(for: .cpu)
                Text("CPU")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                // (13) temperature gauge inside its section
                if let temp = adapter.snapshot.cpuTemperature {
                    TemperatureGauge(temperature: temp)
                }
                UsageBar(fraction: adapter.snapshot.cpuUsage ?? 0, tint: cpuColor)
                    .frame(width: 86)
                Text(adapter.snapshot.cpuUsage.map { percent($0) } ?? "--")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("CPU \(adapter.snapshot.cpuUsage.map { percent($0) } ?? "unknown")")
    }

    // MARK: - GPU

    private var gpuSection: some View {
        sectionContainer(kind: .gpu, color: gpuColor) {
            gpuHeader
            if adapter.snapshot.gpuHistory.count >= 2 {
                Sparkline(values: adapter.snapshot.gpuHistory, color: gpuColor, maxValue: 1, showsZeroBaseline: true)
                    .frame(height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous))
            } else {
                placeholderGraph(history: adapter.snapshot.gpuHistory)
            }
            breakdownList(for: .gpu)
        }
    }

    private var gpuHeader: some View {
        Button {
            toggle(.gpu)
        } label: {
            HStack(spacing: 6) {
                chevron(for: .gpu)
                Text("GPU")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let temp = adapter.snapshot.gpuTemperature {
                    TemperatureGauge(temperature: temp)
                }
                UsageBar(fraction: adapter.snapshot.gpuUsage ?? 0, tint: gpuColor)
                    .frame(width: 86)
                Text(adapter.snapshot.gpuUsage.map { percent($0) } ?? "--")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("GPU \(adapter.snapshot.gpuUsage.map { percent($0) } ?? "unknown")")
    }

    // MARK: - Memory (8)(9)(10) + new tweaks

    private var memorySection: some View {
        sectionContainer(kind: .memory, color: memoryColor) {
            memoryHeader
            // Swap underneath header, above graph — always visible, not on graph
            memorySecondaryRow("Swap", adapter.snapshot.memorySwapUsed)
                .padding(.leading, 16)
            // Graph only memory (swap no longer drawn)
            if adapter.snapshot.memoryHistory.count >= 2 {
                Sparkline(values: adapter.snapshot.memoryHistory, color: memoryColor, maxValue: 1, showsZeroBaseline: true)
                    .frame(height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous))
            } else {
                placeholderGraph(history: adapter.snapshot.memoryHistory)
            }

            if expanded == .memory {
                VStack(alignment: .leading, spacing: 5) {
                    // (new tweak 4) Pressure row with text + circle
                    pressureExpandedRow
                    memorySecondaryRow("Compressed", adapter.snapshot.memoryCompressed)
                    memorySecondaryRow("Cached Files", adapter.snapshot.memoryCached)
                }
                .padding(.leading, 16)
                breakdownList(for: .memory)
            }
        }
    }

    private var pressureExpandedRow: some View {
        let pressure = adapter.snapshot.memoryPressure
        return HStack(spacing: 8) {
            Text("Pressure")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer()
            Circle()
                .fill(memoryPressureColor(pressure))
                .frame(width: 7, height: 7)
                .shadow(color: memoryPressureColor(pressure).opacity(0.6), radius: 1.5)
            Text(pressureLabel(pressure))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(memoryPressureColor(pressure))
        }
    }

    private func pressureLabel(_ pressure: SystemMemoryPressure) -> String {
        switch pressure {
        case .normal: return "Normal"
        case .warning: return "Caution"
        case .critical: return "Critical"
        case .unknown: return "-"
        }
    }

    private var swapGraphColor: Color {
        // Differently-shaded variant of memory's mint — lighter / more translucent
        colorScheme == .light ? Color(red: 0.00, green: 0.52, blue: 0.50).opacity(0.65) : Color.mint.opacity(0.65)
    }

    // (8) chevron now belongs to Memory itself
    // (9) horizontal bar next to Memory title, showing total physical usage
    // (10) pressure badge is dot-only with hover text, hidden when expanded
    private var memoryHeader: some View {
        let snapshot = adapter.snapshot
        let used = snapshot.memoryUsed
        let total = snapshot.memoryTotal
        let fraction = (used != nil && total != nil && total! > 0) ? Double(used!) / Double(total!) : 0
        // Header: no decimals on left, keep unit only on right — "8 / 16 GB"
        let valueText: String = {
            if let u = used, let t = total {
                let left = Self.bytesHeaderLeft(u)
                return "\(left) / \(Self.bytes(t))"
            }
            return "--"
        }()
        let isExpanded = expanded == .memory
        return Button {
            toggle(.memory)
        } label: {
            HStack(spacing: 6) {
                chevron(for: .memory)
                Text("Memory")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                // (10) dot-only pressure indicator — hidden when expanded (new tweak 4)
                if !isExpanded {
                    PressureDot(pressure: snapshot.memoryPressure, color: memoryPressureColor(snapshot.memoryPressure))
                }
                Spacer(minLength: 4)
                // (9) usage bar beside title — with pressure gradient (new tweak 8)
                UsageBar(fraction: fraction, tint: memoryColor, warningTint: memoryPressureWarningTint)
                    .frame(width: 86)
                Text(valueText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Memory \(valueText)")
    }

    private var memoryPressureWarningTint: Color? {
        switch adapter.snapshot.memoryPressure {
        case .warning: return energyYellow // Caution
        case .critical: return energyRed // Critical
        default: return nil
        }
    }

    // MARK: - Battery (3)(4)(11)(13)

    private var batterySection: some View {
        sectionContainer(kind: .battery, color: batteryColor) {
            batteryHeader
            // (11) only when charging, not when merely plugged in
            if adapter.snapshot.batteryIsCharging, adapter.snapshot.batteryHistory.count >= 2 {
                Sparkline(values: adapter.snapshot.batteryHistory, color: batteryColor, maxValue: 1, showsZeroBaseline: true)
                    .frame(height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous))
            }
            // (3) energy apps now live under battery expansion, no separate header
            breakdownList(for: .battery)
        }
    }

    private var batteryHeader: some View {
        let charge = adapter.snapshot.batteryCharge
        let fraction = charge.map { Double($0) / 100.0 } ?? 0
        return Button {
            toggle(.battery)
        } label: {
            HStack(spacing: 6) {
                // (3) chevron like the other sections
                chevron(for: .battery)
                // (4) no battery icon
                Text("Battery")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let temp = adapter.snapshot.batteryTemperature {
                    TemperatureGauge(temperature: temp)
                }
                UsageBar(fraction: fraction, tint: chargeTint(charge ?? 0))
                    .frame(width: 86)
                Text(charge.map { "\($0)%" } ?? "--")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Battery \(charge.map { "\($0) percent" } ?? "unknown")")
    }

    // MARK: - Shared helpers

    private func sectionContainer<Content: View>(kind: SectionKind, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.one) {
            content()
        }
    }

    private func chevron(for kind: SectionKind) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded == kind ? 90 : 0))
    }

    private func placeholderGraph(history: [Double]) -> some View {
        RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
            .fill(Color.controlFill)
            .frame(height: 34)
            .overlay(
                Text(history.isEmpty ? "Measuring…" : "Collecting…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous))
    }

    @ViewBuilder
    private func breakdownList(for kind: SectionKind) -> some View {
        if expanded == kind {
            VStack(alignment: .leading, spacing: 4) {
                if breakdownRows.isEmpty {
                    Text(breakdownLoading ? "Measuring…" : emptyBreakdownText(for: kind))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 20)
                } else {
                    ForEach(breakdownRows) { row in
                        BreakdownProcessRow(row: row, value: breakdownValue(row, for: kind))
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func memorySecondaryRow(_ title: String, _ bytes: UInt64?) -> some View {
        if let bytes {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Self.bytes(bytes))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func emptyBreakdownText(for kind: SectionKind) -> String {
        kind == .battery ? "No apps using significant energy" : "No activity"
    }

    private func breakdownValue(_ row: BreakdownRow, for kind: SectionKind) -> String {
        switch kind {
        case .memory: return Self.bytes(UInt64(row.value))
        case .cpu, .gpu, .battery: return String(format: "%.1f%%", row.value)
        }
    }

    private func toggle(_ kind: SectionKind) {
        if expanded == kind {
            expanded = nil
            breakdownRows = []
            breakdownLoading = false
        } else {
            expanded = kind
            breakdownRows = []
            refreshBreakdown()
        }
    }

    private func refreshBreakdown() {
        guard let kind = expanded else { return }
        lastRefresh = Date()
        breakdownLoading = breakdownRows.isEmpty
        let limit = breakdownLimit
        DispatchQueue.global(qos: .utility).async {
            let rows = fetchBreakdown(kind: kind, limit: limit)
            DispatchQueue.main.async {
                guard expanded == kind else { return }
                breakdownLoading = false
                if !rows.isEmpty || breakdownRows.isEmpty {
                    breakdownRows = rows
                }
            }
        }
    }

    private func fetchBreakdown(kind: SectionKind, limit: Int) -> [BreakdownRow] {
        switch kind {
        case .cpu: return topCPU(limit: limit)
        case .gpu: return topGPU(limit: limit)
        case .memory: return topMemory(limit: limit)
        case .battery: return topEnergy(limit: limit)
        }
    }

    // MARK: - ps-based breakdown (lightweight, no upstream Shell/ResponsibleProcess)

    private func topCPU(limit: Int) -> [BreakdownRow] {
        guard let output = runPs(args: ["-Aceo", "pid,pcpu,comm", "-r"]) else { return [] }
        let parsed = parsePS(output, transform: { Double($0) ?? 0 }, maxRows: max(limit * 10, 120))
        return grouped(parsed, limit: limit)
    }

    private func topMemory(limit: Int) -> [BreakdownRow] {
        guard let output = runPs(args: ["-Aceo", "pid,rss,comm", "-m"]) else { return [] }
        let parsed = parsePS(output, transform: { (Double($0) ?? 0) * 1024 }, maxRows: max(limit * 10, 120))
            .map { row -> BreakdownRow in
                if let footprint = physicalFootprint(of: row.pid) {
                    return BreakdownRow(id: row.id, pid: row.pid, name: row.name, value: footprint)
                }
                return row
            }
        return grouped(parsed, limit: limit)
    }

    private func topGPU(limit: Int) -> [BreakdownRow] {
        // GPU per-process requires IOKit accelerator sampling (two samples ~2s apart).
        // For the panel we approximate with CPU top; a future iteration can wire
        // the true GPU sampler when needed without changing the UI seam.
        return topCPU(limit: limit)
    }

    private func topEnergy(limit: Int) -> [BreakdownRow] {
        let cpuRows = topCPU(limit: max(limit * 3, 12))
        let filtered = cpuRows.filter { $0.value >= 1.5 }
        return Array(filtered.prefix(limit))
    }

    private func runPs(args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func parsePS(_ output: String, transform: (String) -> Double, maxRows: Int) -> [BreakdownRow] {
        var rows: [BreakdownRow] = []
        for line in output.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard cols.count == 3, let pidInt = Int32(cols[0]) else { continue }
            let value = transform(String(cols[1]))
            guard value > 0 else { continue }
            let name = String(cols[2]).trimmingCharacters(in: .whitespaces)
            rows.append(BreakdownRow(id: pidInt, pid: pid_t(pidInt), name: name, value: value))
            if rows.count >= maxRows { break }
        }
        return rows
    }

    private func grouped(_ rows: [BreakdownRow], limit: Int) -> [BreakdownRow] {
        // Lightweight grouping without ResponsibleProcess — sum by process name.
        // This avoids depending on upstream's internal `ResponsibleProcess` mapping
        // while still collapsing helper processes that share a display name.
        var totals: [String: Double] = [:]
        var pidForName: [String: pid_t] = [:]
        for row in rows {
            let key = displayName(for: row.pid, fallback: row.name)
            totals[key, default: 0] += row.value
            if pidForName[key] == nil { pidForName[key] = row.pid }
        }
        return totals.sorted { $0.value > $1.value }.prefix(limit).map { name, value in
            let pid = pidForName[name] ?? 0
            return BreakdownRow(id: Int32(pid), pid: pid, name: name, value: value)
        }
    }

    private func displayName(for pid: pid_t, fallback: String) -> String {
        // `NSRunningApplication` is main-thread only; the breakdown runs on a
        // utility queue, so only use it when already on main.
        if Thread.isMainThread,
           let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let name = String(cString: buffer)
            if !name.isEmpty { return name }
        }
        return fallback.trimmingCharacters(in: .whitespaces)
    }

    private func physicalFootprint(of pid: pid_t) -> Double? {
        var info = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
            }
        }
        guard status == 0, info.ri_phys_footprint > 0 else { return nil }
        return Double(info.ri_phys_footprint)
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

    static func bytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(value))
    }

    /// Header left side: integer without decimals, no unit — e.g. "8" from "8 GB" or "1.5 GB" → "2"
    static func bytesHeaderLeft(_ value: UInt64) -> String {
        let raw = byteFormatter.string(fromByteCount: Int64(value))
        let parts = raw.split(separator: " ")
        guard let numStr = parts.first, let num = Double(numStr) else {
            return raw.split(separator: " ").first.map(String.init) ?? raw
        }
        return String(Int(num.rounded()))
    }

    private func chargeTint(_ charge: Int) -> Color {
        if charge < 20 { return energyRed }
        if charge < 40 { return energyYellow }
        return batteryColor
    }

    private func memoryPressureColor(_ pressure: SystemMemoryPressure) -> Color {
        switch pressure {
        case .normal: return energyGreen
        case .warning: return energyYellow
        case .critical: return energyRed
        case .unknown: return .secondary
        }
    }

    // (12) distinct color per section
    private var cpuColor: Color { sectionColor(.cpu) }
    private var gpuColor: Color { sectionColor(.gpu) }
    private var memoryColor: Color { sectionColor(.memory) }
    private var batteryColor: Color { sectionColor(.battery) }

    private var energyGreen: Color { sectionColor(.memory) }
    private var energyYellow: Color { colorScheme == .light ? Color(red: 0.56, green: 0.36, blue: 0) : .yellow }
    private var energyRed: Color { colorScheme == .light ? Color(red: 0.68, green: 0.08, blue: 0.10) : .red }

    private func sectionColor(_ kind: SectionKind, fallback: Color? = nil) -> Color {
        switch kind {
        case .cpu:
            return colorScheme == .light ? Color(red: 0.68, green: 0.30, blue: 0) : .orange
        case .gpu:
            return colorScheme == .light ? Color(red: 0.00, green: 0.43, blue: 0.54) : .cyan
        case .memory:
            return colorScheme == .light ? Color(red: 0.00, green: 0.44, blue: 0.40) : .mint
        case .battery:
            return colorScheme == .light ? Color(red: 0.00, green: 0.44, blue: 0.18) : .green
        }
    }
}

// MARK: - Header accessory

private struct ActivityMonitorButton: View {
    @State private var isHovered = false

    var body: some View {
        Button {
            let fallback = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") ?? fallback
            NSWorkspace.shared.open(url)
        } label: {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(isHovered ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open Activity Monitor")
        .accessibilityLabel("Open Activity Monitor")
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Small views

/// Thin capacity bar for CPU/GPU/Memory/Battery usage (per-section color).
/// When `warningTint` is set (memory pressure), the leading edge gradients into it.
private struct UsageBar: View {
    let fraction: Double
    var tint: Color? = nil
    var warningTint: Color? = nil

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(barFill(width: proxy.size.width))
                    .frame(width: max(3, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }

    private func barFill(width: CGFloat) -> AnyShapeStyle {
        let base = tint ?? .accentColor
        guard let warning = warningTint else {
            return AnyShapeStyle(base)
        }
        // Gradient from base into warning at the trailing tip
        return AnyShapeStyle(
            LinearGradient(
                stops: [
                    .init(color: base, location: 0.0),
                    .init(color: base, location: 0.72),
                    .init(color: warning, location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
}

/// (10) dot-only memory pressure indicator — text shows on hover.
private struct PressureDot: View {
    let pressure: SystemMemoryPressure
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.6), radius: 1.5)
            .help(label)
            .accessibilityLabel(label)
    }

    private var label: String {
        switch pressure {
        case .normal: return "Memory pressure: Normal"
        case .warning: return "Memory pressure: Caution"
        case .critical: return "Memory pressure: Critical"
        case .unknown: return "Memory pressure: Unknown"
        }
    }
}

/// Temperature readout — number only, colored when hot.
private struct TemperatureGauge: View {
    let temperature: Double?
    var size: CGFloat = 32

    private var warningColor: Color? {
        guard let temp = temperature else { return nil }
        if temp >= 85 { return Color.red }
        if temp >= 75 { return Color.yellow }
        return nil
    }

    var body: some View {
        Group {
            if let temp = temperature {
                Text("\(Int(temp.rounded()))°")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(warningColor ?? .secondary)
            } else {
                Text("--")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 28, alignment: .trailing)
        .help(temperature.map { String(format: "%.0f °C", $0) } ?? "No reading")
        .accessibilityLabel(temperature.map { String(format: "%.0f degrees", $0) } ?? "No temperature")
    }
}

private struct BreakdownProcessRow: View {
    let row: BreakdownRow
    let value: String

    var body: some View {
        HStack(spacing: 7) {
            // Use app icon when we can resolve a running app; fallback to generic.
            if let app = NSRunningApplication(processIdentifier: row.pid), let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            Text(row.name)
                .font(.system(size: 10.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 20)
        .contentShape(Rectangle())
    }
}

// MARK: - Helpers

private extension View {
    func erased() -> AnyView { AnyView(self) }
}
