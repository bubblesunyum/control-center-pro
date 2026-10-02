// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import SwiftUI

// MARK: - Live source

/// The production `ProjectsSource`: discovery, runs, and status straight off
/// the `ProjectLaunchAdapter`. Board URLs ride the outcome back to the view,
/// which opens them — this layer never opens anything itself.
@MainActor
public final class LiveProjectsSource: ProjectsSource {
    private let adapter: ProjectLaunchAdapter

    public convenience init() {
        self.init(adapter: ProjectLaunchAdapter())
    }

    public init(adapter: ProjectLaunchAdapter) {
        self.adapter = adapter
    }

    public func fetchSections() async -> [ProjectGroupViewModel] {
        await adapter.discover()
        let projects = adapter.projects
        let adapterForStatus = adapter
        var runningByID: [String: Bool] = [:]
        await withTaskGroup(of: (String, Bool).self) { group in
            for project in projects {
                for target in project.targets {
                    group.addTask {
                        let status = await adapterForStatus.status(of: target)
                        return (target.id, status == .running)
                    }
                }
            }
            for await (id, isRunning) in group {
                runningByID[id] = isRunning
            }
        }
        return projects.map { project in
            ProjectGroupViewModel(
                id: project.rootPath,
                directoryName: project.name,
                displayName: project.displayName,
                rows: project.targets.map { target in
                    ProjectRowViewModel(
                        id: target.id,
                        label: target.label,
                        isRunning: runningByID[target.id] ?? false,
                        busyText: target.busy,
                        opensURL: target.kind == .board)
                })
        }
    }

    public func run(rowID: String) async -> ProjectActionOutcome {
        guard let target = findTarget(id: rowID) else { return .failed }
        switch await adapter.run(target) {
        case .started(let url): return .started(url)
        case .alreadyRunning(let url): return .alreadyRunning(url)
        case .failed: return .failed
        }
    }

    public func stop(rowID: String) async -> ProjectActionOutcome {
        guard let target = findTarget(id: rowID) else { return .failed }
        await adapter.stop(target)
        return .stopped
    }

    public func restart(rowID: String) async -> ProjectActionOutcome {
        guard let target = findTarget(id: rowID) else { return .failed }
        switch await adapter.restart(target) {
        case .started(let url): return .restarted(url)
        case .alreadyRunning(let url): return .alreadyRunning(url)
        case .failed: return .failed
        }
    }

    public func open(_ url: URL) async {
        _ = NSWorkspace.shared.open(url)
    }

    private func findTarget(id: String) -> ProjectTarget? {
        for project in adapter.projects {
            if let target = project.targets.first(where: { $0.id == id }) {
                return target
            }
        }
        return nil
    }
}

// MARK: - View models

/// One launchable target inside a project section, as the widget draws it.
public struct ProjectRowViewModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let isRunning: Bool
    /// Static toml `busy` text, shown only while the row has in-flight work
    /// (see `ProjectsModel/busyMessage(for:)`). Alone it never means busy.
    public let busyText: String?
    /// URL tasks open their board after serving instead of just flipping state.
    public let opensURL: Bool

    public init(id: String, label: String, isRunning: Bool, busyText: String? = nil, opensURL: Bool = false) {
        self.id = id
        self.label = label
        self.isRunning = isRunning
        self.busyText = busyText
        self.opensURL = opensURL
    }

    /// Settled-state gates; in-flight busy is overlaid by the model, so a
    /// static `busyText` alone never disables anything.
    public var canRun: Bool { !isRunning }
    /// Stop and restart are only valid on a settled, running target.
    public var canStop: Bool { isRunning }
    public var canRestart: Bool { isRunning }
}

/// One project section: its directory and, when the toml names one, its
/// display name, over its target rows.
public struct ProjectGroupViewModel: Identifiable, Equatable, Sendable {
    /// The project directory path; stable across renames of the display name.
    public let id: String
    public let directoryName: String
    public let displayName: String?
    public var rows: [ProjectRowViewModel]

    public init(id: String, directoryName: String, displayName: String? = nil, rows: [ProjectRowViewModel] = []) {
        self.id = id
        self.directoryName = directoryName
        self.displayName = displayName
        self.rows = rows
    }

    /// Header line: the directory name, with the toml display name alongside
    /// when one is known and differs. The compare is case- and
    /// separator-insensitive, so `PSYMAIL-MINI` vs `PSYMAIL MINI` collapses;
    /// the displayed form stays the exact directory name.
    public var headerTitle: String {
        guard let displayName, !displayName.isEmpty,
              Self.canonical(displayName) != Self.canonical(directoryName)
        else {
            return directoryName
        }
        return "\(directoryName) · \(displayName)"
    }

    private static func canonical(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// What a run/stop/restart tap came to. The view-model exposes the outcome;
/// the view just opens the URL and hides the panel.
public enum ProjectActionOutcome: Equatable, Sendable {
    case started(URL?)
    case alreadyRunning(URL)
    case stopped
    case restarted(URL?)
    case failed

    public var url: URL? {
        switch self {
        case .started(let url): return url
        case .alreadyRunning(let url): return url
        case .stopped: return nil
        case .restarted(let url): return url
        case .failed: return nil
        }
    }

    /// Whether the tap opened (or should open) a board rather than just
    /// flipping state.
    public var opensBoard: Bool { url != nil }
}

// MARK: - Source seam

/// The seam a test stands a fake in for: process discovery and spawning are
/// not things a test should trigger.
public protocol ProjectsSource: AnyObject, Sendable {
    func fetchSections() async -> [ProjectGroupViewModel]
    func run(rowID: String) async -> ProjectActionOutcome
    func stop(rowID: String) async -> ProjectActionOutcome
    func restart(rowID: String) async -> ProjectActionOutcome
    func open(_ url: URL) async
}

/// Empty source for tests/previews: no projects, every action fails,
// opening still reaches the browser so URL plumbing is testable live.
public final class EmptyProjectsSource: ProjectsSource {
    public init() {}

    public func fetchSections() async -> [ProjectGroupViewModel] { [] }
    public func run(rowID: String) async -> ProjectActionOutcome { .failed }
    public func stop(rowID: String) async -> ProjectActionOutcome { .failed }
    public func restart(rowID: String) async -> ProjectActionOutcome { .failed }
    public func open(_ url: URL) async { NSWorkspace.shared.open(url) }
}

// MARK: - Model

/// The widget's model: discovered project sections plus the in-flight taps.
///
/// Busy is transient only: the toml `busy` text rides the row as `busyText`,
/// and the spinner/message appear solely while the row's id sits in
/// `busyIDs` (this tap's async work, so the row answers instantly even
/// before the next poll lands). A refresh never makes a row busy by itself.
@MainActor
@Observable
public final class ProjectsModel {
    public private(set) var sections: [ProjectGroupViewModel] = []
    public private(set) var busyIDs: Set<String> = []

    @ObservationIgnored private let source: any ProjectsSource
    @ObservationIgnored private let pollInterval: TimeInterval
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    public convenience init() {
        self.init(source: LiveProjectsSource())
    }

    public init(source: any ProjectsSource, pollInterval: TimeInterval = 5) {
        self.source = source
        self.pollInterval = pollInterval
    }

    /// Whether the row has in-flight work. Static `busyText` alone never
    /// counts — only `busyIDs` does.
    public func isBusy(_ row: ProjectRowViewModel) -> Bool {
        busyIDs.contains(row.id)
    }

    public func canRun(_ row: ProjectRowViewModel) -> Bool {
        row.canRun && !busyIDs.contains(row.id)
    }

    public func canStop(_ row: ProjectRowViewModel) -> Bool {
        row.canStop && !busyIDs.contains(row.id)
    }

    public func canRestart(_ row: ProjectRowViewModel) -> Bool {
        row.canRestart && !busyIDs.contains(row.id)
    }

    /// The message to draw while busy: the row's static text, gated on
    /// in-flight work and nil whenever settled. The generic fallback wording
    /// is the view's call.
    public func busyMessage(for row: ProjectRowViewModel) -> String? {
        guard busyIDs.contains(row.id) else { return nil }
        return row.busyText
    }

    /// One discovery pass. Public so tests can drive it deterministically
    /// instead of waiting on the poll loop.
    public func refresh() async {
        sections = await source.fetchSections()
    }

    /// Start discovery polling. Called when the panel opens.
    public func activate() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    /// Stop discovery polling. Called when the panel closes — with the panel
    /// shut, the app's job is to cost nothing.
    public func deactivate() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func run(_ row: ProjectRowViewModel) async -> ProjectActionOutcome {
        await perform(row, allowed: row.canRun) { await source.run(rowID: $0) }
    }

    public func stop(_ row: ProjectRowViewModel) async -> ProjectActionOutcome {
        await perform(row, allowed: row.canStop) { await source.stop(rowID: $0) }
    }

    public func restart(_ row: ProjectRowViewModel) async -> ProjectActionOutcome {
        await perform(row, allowed: row.canRestart) { await source.restart(rowID: $0) }
    }

    /// One tap's async work: the per-row guard picks the valid states, the
    /// busy set serializes re-entrant taps, and the refresh publishes.
    private func perform(
        _ row: ProjectRowViewModel,
        allowed: Bool,
        action: (String) async -> ProjectActionOutcome
    ) async -> ProjectActionOutcome {
        guard allowed, !busyIDs.contains(row.id) else { return .failed }
        busyIDs.insert(row.id)
        defer { busyIDs.remove(row.id) }
        let outcome = await action(row.id)
        await refresh()
        return outcome
    }

    public func open(_ url: URL) async {
        await source.open(url)
    }
}

// MARK: - Widget

/// Project launch targets, grouped by project with run/stop/restart.
@MainActor
public final class ProjectsWidget: CCPWidget {
    public static let descriptor = WidgetDescriptor(
        id: "projects",
        title: "Projects",
        symbolName: "play.square.stack",
        size: .tall,
        isMinimizable: true
    )

    private let model: ProjectsModel

    /// Weight-matched restart glyph: the `arrow.clockwise` outline reads
    /// disabled next to the `.fill` play/stop at caption size.
    public static let restartSymbolName = "arrow.triangle.2.circlepath"

    public init() {
        self.model = ProjectsModel(source: LiveProjectsSource())
    }

    /// Test seam: a widget backed by a fake source.
    init(source: any ProjectsSource) {
        self.model = ProjectsModel(source: source)
    }

    public func makeView() -> some View {
        ProjectsContent(model: model)
    }

    public func activate() { model.activate() }
    public func deactivate() { model.deactivate() }
}

// MARK: - Content

private struct ProjectsContent: View {
    @Bindable var model: ProjectsModel
    @Environment(\.panelArrangement) private var arrangement
    @Environment(\.currentWidgetID) private var currentWidgetID

    /// Persisted on the layout's placement, so a minimized Projects stays
    /// minimized across launches and travels with the widget between lanes.
    private var isMinimized: Bool {
        guard let arrangement, let id = currentWidgetID else { return false }
        return arrangement.layout.lanes.joined().first { $0.id == id }?.isMinimized ?? false
    }

    private func toggleMinimized() {
        guard let arrangement, let id = currentWidgetID else { return }
        arrangement.setMinimized(id, to: !isMinimized)
    }

    var body: some View {
        WidgetCard(ProjectsWidget.descriptor, isMinimized: isMinimized, onToggleMinimized: toggleMinimized) {
            if isMinimized {
                minimizedSummary
            } else if model.sections.isEmpty {
                Text("No projects found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Space.half) {
                    ForEach(model.sections) { group in
                        ProjectGroupSection(group: group, model: model)
                        if group.id != model.sections.last?.id {
                            WidgetSectionGap()
                        }
                    }
                }
                .padding(.top, Space.half)
            }
        }
        .animation(.smooth(duration: 0.2), value: isMinimized)
    }

    /// Minimized form: one running count, the way the header's count badge
    /// would read if the card wore one.
    private var minimizedSummary: some View {
        let running = model.sections.flatMap(\.rows).filter(\.isRunning).count
        return Text(running == 0 ? "All stopped" : "\(running) running")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Group section

private struct ProjectGroupSection: View {
    let group: ProjectGroupViewModel
    @Bindable var model: ProjectsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.half) {
            WidgetSectionLabel(group.headerTitle)
                .padding(.horizontal, Space.half)
            if group.rows.isEmpty {
                Text("nothing runnable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.half)
                    .accessibilityLabel("nothing runnable in \(group.headerTitle)")
            } else {
                ForEach(group.rows) { row in
                    ProjectTargetRow(row: row, model: model)
                }
            }
        }
    }
}

// MARK: - Target row

private struct ProjectTargetRow: View {
    let row: ProjectRowViewModel
    @Bindable var model: ProjectsModel
    @Environment(\.hidePanel) private var hidePanel

    private var isBusy: Bool { model.isBusy(row) }

    var body: some View {
        HStack(spacing: Space.half) {
            statusDot
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
                    .accessibilityLabel("\(row.label) busy")
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(row.label)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if isBusy {
                    Text(model.busyMessage(for: row) ?? "Working…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            actionButtons
        }
        .padding(.horizontal, Space.half)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.label), \(row.isRunning ? "running" : "stopped")")
        .accessibilityAction(named: "Run \(row.label)") { Task { await runTarget() } }
        .accessibilityAction(named: "Stop \(row.label)") { Task { await stopTarget() } }
        .accessibilityAction(named: "Restart \(row.label)") { Task { await restartTarget() } }
    }

    private var statusDot: some View {
        Circle()
            .fill(row.isRunning ? Color.projectRunning : Color.secondary.opacity(0.4))
            .frame(width: Space.one, height: Space.one)
            .accessibilityHidden(true)
    }

    private var actionButtons: some View {
        HStack(spacing: Space.quarter) {
            ProjectActionButton(systemImage: "play.fill", label: "Run \(row.label)", isEnabled: model.canRun(row)) {
                await runTarget()
            }
            ProjectActionButton(systemImage: "stop.fill", label: "Stop \(row.label)", isEnabled: model.canStop(row)) {
                await stopTarget()
            }
            ProjectActionButton(systemImage: ProjectsWidget.restartSymbolName, label: "Restart \(row.label)", isEnabled: model.canRestart(row)) {
                await restartTarget()
            }
        }
    }

    private func runTarget() async {
        await perform(verb: "run", past: "started", icon: "play.fill") { await model.run(row) }
    }

    private func stopTarget() async {
        await perform(verb: "stop", past: "stopped", icon: "stop.fill") { await model.stop(row) }
    }

    private func restartTarget() async {
        await perform(verb: "restart", past: "restarted", icon: ProjectsWidget.restartSymbolName) { await model.restart(row) }
    }

    /// One tap's outcome: a HUD either way, and a board that just opened gets
    /// the panel out of its way. Failures keep the panel open for the retry.
    private func perform(
        verb: String, past: String, icon: String,
        action: () async -> ProjectActionOutcome
    ) async {
        switch await action() {
        case .started(let url), .restarted(let url):
            HUD.show(icon: icon, message: "\(row.label) \(past)")
            if let url {
                await model.open(url)
                hidePanel?()
            }
        case .alreadyRunning(let url):
            HUD.show(icon: icon, message: "\(row.label) board opened")
            await model.open(url)
            hidePanel?()
        case .stopped:
            HUD.show(icon: icon, message: "\(row.label) stopped")
        case .failed:
            HUD.show(icon: icon, message: "Couldn't \(verb) \(row.label)")
        }
    }
}

// MARK: - Action button

private struct ProjectActionButton: View {
    let systemImage: String
    let label: String
    let isEnabled: Bool
    let action: () async -> Void

    @State private var isRunning = false

    var body: some View {
        Button {
            guard !isRunning else { return }
            isRunning = true
            Task {
                await action()
                isRunning = false
            }
        } label: {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: Layout.rowActionSize, height: Layout.rowActionSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverChip()
        .disabled(!isEnabled || isRunning)
        .help(label)
        .accessibilityLabel(label)
    }
}

