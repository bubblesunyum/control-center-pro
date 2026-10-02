// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import Foundation
import XCTest
@testable import CCPUI

/// The Projects widget's state contract, driven through a fake source — no
/// processes are ever spawned: buttons enable only in valid states, sections
/// render grouped, and URL tasks open their board.
@MainActor
final class ProjectsWidgetTests: XCTestCase {
    func testDescriptorIsTallMinimizableProjects() {
        let descriptor = ProjectsWidget.descriptor
        XCTAssertEqual(descriptor.id, WidgetID("projects"))
        XCTAssertEqual(descriptor.size, .tall)
        XCTAssertTrue(descriptor.isMinimizable)
    }

    func testHeaderShowsDirectoryNameAloneWithoutDisplayName() {
        let group = ProjectGroupViewModel(id: "/x/api", directoryName: "api")
        XCTAssertEqual(group.headerTitle, "api")
    }

    func testHeaderPairsDirectoryNameWithTomlDisplayName() {
        let group = ProjectGroupViewModel(id: "/x/api", directoryName: "api", displayName: "API Server")
        XCTAssertEqual(group.headerTitle, "api · API Server")
    }

    func testHeaderDedupesDisplayNameMatchingDirectoryName() {
        let group = ProjectGroupViewModel(id: "/x/api", directoryName: "api", displayName: "api")
        XCTAssertEqual(group.headerTitle, "api")
    }

    func testStoppedRowOnlyRuns() {
        let row = ProjectRowViewModel(id: "a", label: "Serve", isRunning: false)
        XCTAssertTrue(row.canRun)
        XCTAssertFalse(row.canStop)
        XCTAssertFalse(row.canRestart)
    }

    func testRunningRowStopsOrRestartsButNeverRuns() {
        let row = ProjectRowViewModel(id: "a", label: "Serve", isRunning: true)
        XCTAssertFalse(row.canRun)
        XCTAssertTrue(row.canStop)
        XCTAssertTrue(row.canRestart)
    }

    func testBusyRowDisablesEveryButton() {
        let stopped = ProjectRowViewModel(id: "a", label: "Serve", isRunning: false, busyMessage: "Starting…")
        XCTAssertFalse(stopped.canRun)
        XCTAssertFalse(stopped.canStop)
        XCTAssertFalse(stopped.canRestart)
        let running = ProjectRowViewModel(id: "b", label: "Serve", isRunning: true, busyMessage: "Stopping…")
        XCTAssertFalse(running.canRun)
        XCTAssertFalse(running.canStop)
        XCTAssertFalse(running.canRestart)
    }

    func testOutcomeExposesBoardURL() {
        let url = URL(string: "http://localhost:3000/")!
        XCTAssertEqual(ProjectActionOutcome.started(url).url, url)
        XCTAssertEqual(ProjectActionOutcome.alreadyRunning(url).url, url)
        XCTAssertEqual(ProjectActionOutcome.restarted(url).url, url)
        XCTAssertNil(ProjectActionOutcome.stopped.url)
        XCTAssertNil(ProjectActionOutcome.failed.url)
        XCTAssertTrue(ProjectActionOutcome.started(url).opensBoard)
        XCTAssertFalse(ProjectActionOutcome.stopped.opensBoard)
    }

    func testRefreshLoadsGroupedSections() async {
        let (model, _) = makeModel()
        XCTAssertTrue(model.sections.isEmpty)
        await model.refresh()
        XCTAssertEqual(model.sections.count, 2)
        XCTAssertEqual(model.sections[0].rows.count, 2)
        XCTAssertEqual(model.sections[0].headerTitle, "api · API Server")
    }

    func testRunTransitionsStoppedToRunning() async {
        let (model, fake) = makeModel()
        await model.refresh()
        let row = model.sections[0].rows[0]
        XCTAssertFalse(row.isRunning)
        let outcome = await model.run(row)
        if case .started(let url) = outcome {
            XCTAssertNotNil(url)
        } else {
            XCTFail("expected started, got \(outcome)")
        }
        XCTAssertEqual(fake.runCalls, ["api/serve"])
        XCTAssertTrue(model.sections[0].rows[0].isRunning)
    }

    func testRunOnRunningRowFailsWithoutSpawning() async {
        let (model, fake) = makeModel()
        await model.refresh()
        let row = model.sections[0].rows[1]
        XCTAssertTrue(row.isRunning)
        let outcome = await model.run(row)
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(fake.runCalls.isEmpty)
    }

    func testAlreadyRunningOpensWithoutSpawning() async {
        let (model, fake) = makeModel(urlTasksAlreadyRunning: true)
        await model.refresh()
        let row = model.sections[0].rows[0]
        let outcome = await model.run(row)
        if case .alreadyRunning(let url) = outcome {
            await model.open(url)
            XCTAssertEqual(fake.openedURLs, [url])
        } else {
            XCTFail("expected alreadyRunning, got \(outcome)")
        }
        // Reused the running board: nothing was spawned.
        XCTAssertTrue(fake.runCalls.isEmpty)
    }

    func testStopTransitionsRunningToStopped() async {
        let (model, fake) = makeModel()
        await model.refresh()
        let row = model.sections[0].rows[1]
        XCTAssertTrue(row.isRunning)
        let outcome = await model.stop(row)
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(fake.stopCalls, ["api/worker"])
        XCTAssertFalse(model.sections[0].rows[1].isRunning)
    }

    func testStopOnStoppedRowFailsWithoutActing() async {
        let (model, fake) = makeModel()
        await model.refresh()
        let outcome = await model.stop(model.sections[0].rows[0])
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(fake.stopCalls.isEmpty)
    }

    func testRestartKeepsRunningRowRunning() async {
        let (model, fake) = makeModel()
        await model.refresh()
        let outcome = await model.restart(model.sections[0].rows[1])
        if case .restarted = outcome {
            // Expected.
        } else {
            XCTFail("expected restarted, got \(outcome)")
        }
        XCTAssertEqual(fake.restartCalls, ["api/worker"])
        XCTAssertTrue(model.sections[0].rows[1].isRunning)
    }

    func testRestartOnStoppedRowFailsWithoutActing() async {
        let (model, fake) = makeModel()
        await model.refresh()
        let outcome = await model.restart(model.sections[0].rows[0])
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(fake.restartCalls.isEmpty)
    }

    func testBusyIDsClearAfterAction() async {
        let (model, _) = makeModel()
        await model.refresh()
        _ = await model.run(model.sections[0].rows[0])
        XCTAssertTrue(model.busyIDs.isEmpty)
    }

    // MARK: - Live source over a fake launch source

    func testLiveSourceMapsProjectsToGroups() async {
        let (source, _) = makeLiveSource()
        let sections = await source.fetchSections()

        XCTAssertEqual(sections.count, 2)
        let api = sections.first(where: { $0.directoryName == "api" })
        XCTAssertEqual(api?.id, "/dev/api")
        XCTAssertNil(api?.displayName)
        XCTAssertEqual(api?.headerTitle, "api")
        XCTAssertEqual(api?.rows.map(\.label), ["Board"])
        XCTAssertEqual(api?.rows.first?.opensURL, true)
        XCTAssertEqual(api?.rows.first?.busyMessage, nil)
        let web = sections.first(where: { $0.directoryName == "web" })
        XCTAssertEqual(web?.rows.map(\.label), ["app.sh"])
        XCTAssertEqual(web?.rows.first?.opensURL, false)
    }

    func testLiveSourceBoardRunReturnsStartedURLWithoutOpening() async {
        let url = URL(string: "http://localhost:7391/")!
        let (source, fake) = makeLiveSource { $0.upResult = .started(url) }
        let boardRowID = await boardRowID(in: source)

        let outcome = await source.run(rowID: boardRowID)

        XCTAssertEqual(outcome, .started(url))
        XCTAssertEqual(fake.upCount, 1)
        XCTAssertTrue(fake.spawned.isEmpty)
        XCTAssertTrue(fake.opened.isEmpty, "opening is the view's job — the source only reports the URL")
    }

    func testLiveSourceAlreadyRunningReusesURLWithoutSpawning() async {
        let url = URL(string: "http://localhost:7393/")!
        let (source, fake) = makeLiveSource { $0.runningURL = url }
        let sections = await source.fetchSections()
        let boardRow = sections.flatMap(\.rows).first(where: { $0.opensURL })
        XCTAssertEqual(boardRow?.isRunning, true)

        let outcome = await source.run(rowID: boardRow!.id)

        XCTAssertEqual(outcome, .alreadyRunning(url))
        XCTAssertEqual(fake.upCount, 0, "a running board must be reused, not relaunched")
        XCTAssertTrue(fake.spawned.isEmpty)
        XCTAssertTrue(fake.opened.isEmpty)
    }

    func testLiveSourceBoardFailureMapsToFailed() async {
        let (source, _) = makeLiveSource()
        let outcome = await source.run(rowID: boardRowID(in: source))
        XCTAssertEqual(outcome, .failed)
    }

    func testLiveSourceProcessRunStopRestart() async {
        let (source, fake) = makeLiveSource()
        let sections = await source.fetchSections()
        let rowID = sections.first(where: { $0.directoryName == "web" })!.rows.first!.id

        let started = await source.run(rowID: rowID)
        XCTAssertEqual(started, .started(nil))
        XCTAssertEqual(fake.spawned.count, 1)
        var current = await source.fetchSections()
        XCTAssertEqual(current.first(where: { $0.directoryName == "web" })!.rows.first!.isRunning, true)

        let stopped = await source.stop(rowID: rowID)
        XCTAssertEqual(stopped, .stopped)
        current = await source.fetchSections()
        XCTAssertEqual(current.first(where: { $0.directoryName == "web" })!.rows.first!.isRunning, false)

        let restarted = await source.restart(rowID: rowID)
        XCTAssertEqual(restarted, .restarted(nil))
        XCTAssertEqual(fake.spawned.count, 2, "restart stops then spawns again")
    }

    func testLiveSourceUnknownRowIDFailsWithoutActing() async {
        let (source, fake) = makeLiveSource()
        _ = await source.fetchSections()

        let runUnknown = await source.run(rowID: "nope")
        XCTAssertEqual(runUnknown, .failed)
        let stopUnknown = await source.stop(rowID: "nope")
        XCTAssertEqual(stopUnknown, .failed)
        let restartUnknown = await source.restart(rowID: "nope")
        XCTAssertEqual(restartUnknown, .failed)
        XCTAssertTrue(fake.spawned.isEmpty)
        XCTAssertEqual(fake.upCount, 0)
    }

    func testLiveSourceMapsDisplayNameAndBusy() async {
        let (source, _) = makeLiveSource {
            $0.dashboardTOML["/dev/api/dashboard.toml"] = """
                [project]
                name = "API Server"

                [[task]]
                name = "worker"
                command = ["scripts/worker.sh"]
                label = "Worker"
                busy = "working…"
                """
        }
        let sections = await source.fetchSections()

        let api = sections.first(where: { $0.directoryName == "api" })
        XCTAssertEqual(api?.displayName, "API Server")
        XCTAssertEqual(api?.headerTitle, "api · API Server")
        let worker = api?.rows.first(where: { $0.label == "Worker" })
        XCTAssertEqual(worker?.busyMessage, "working…")
        XCTAssertTrue(worker?.isBusy ?? false)
    }

    // MARK: - Helpers

    private func makeModel(urlTasksAlreadyRunning: Bool = false) -> (ProjectsModel, FakeProjectsSource) {
        let fake = FakeProjectsSource(alreadyRunning: urlTasksAlreadyRunning)
        return (ProjectsModel(source: fake, pollInterval: 3600), fake)
    }

    private func makeLiveSource(
        _ configure: (FakeLaunchSource) -> Void = { _ in }
    ) -> (LiveProjectsSource, FakeLaunchSource) {
        let fake = FakeLaunchSource()
        configure(fake)
        let adapter = ProjectLaunchAdapter(
            source: fake, defaults: ephemeralDefaults(), stopGraceInterval: 0)
        return (LiveProjectsSource(adapter: adapter), fake)
    }

    private func ephemeralDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ccp.projectsWidget.tests.\(UUID().uuidString)") ?? .standard
    }

    private func boardRowID(in source: LiveProjectsSource) async -> String {
        let sections = await source.fetchSections()
        return sections.flatMap(\.rows).first(where: { $0.opensURL })!.id
    }
}

/// Stand-in for the not-yet-landed adapter: an in-memory section list whose
/// actions mutate state and record calls instead of spawning anything.
final class FakeProjectsSource: ProjectsSource, @unchecked Sendable {
    private var groups: [ProjectGroupViewModel] = [
        ProjectGroupViewModel(id: "/x/api", directoryName: "api", displayName: "API Server", rows: [
            ProjectRowViewModel(id: "api/serve", label: "Serve", isRunning: false, opensURL: true),
            ProjectRowViewModel(id: "api/worker", label: "Worker", isRunning: true),
        ]),
        ProjectGroupViewModel(id: "/x/web", directoryName: "web", rows: [
            ProjectRowViewModel(id: "web/dev", label: "Dev", isRunning: false, opensURL: true),
        ]),
    ]
    private let alreadyRunning: Bool
    private(set) var runCalls: [String] = []
    private(set) var stopCalls: [String] = []
    private(set) var restartCalls: [String] = []
    private(set) var openedURLs: [URL] = []

    init(alreadyRunning: Bool = false) {
        self.alreadyRunning = alreadyRunning
    }

    func fetchSections() async -> [ProjectGroupViewModel] { groups }

    func run(rowID: String) async -> ProjectActionOutcome {
        if alreadyRunning, let url = boardURL(for: rowID) {
            return .alreadyRunning(url)
        }
        runCalls.append(rowID)
        setRunning(true, rowID: rowID)
        return .started(boardURL(for: rowID))
    }

    func stop(rowID: String) async -> ProjectActionOutcome {
        stopCalls.append(rowID)
        setRunning(false, rowID: rowID)
        return .stopped
    }

    func restart(rowID: String) async -> ProjectActionOutcome {
        restartCalls.append(rowID)
        return .restarted(boardURL(for: rowID))
    }

    func open(_ url: URL) async {
        openedURLs.append(url)
    }

    private func boardURL(for rowID: String) -> URL? {
        rowOpensURL(rowID) ? URL(string: "http://localhost:3000/") : nil
    }

    private func rowOpensURL(_ rowID: String) -> Bool {
        groups.flatMap(\.rows).first { $0.id == rowID }?.opensURL ?? false
    }

    private func setRunning(_ running: Bool, rowID: String) {
        for gi in groups.indices {
            for ri in groups[gi].rows.indices where groups[gi].rows[ri].id == rowID {
                let old = groups[gi].rows[ri]
                groups[gi].rows[ri] = ProjectRowViewModel(
                    id: old.id, label: old.label, isRunning: running,
                    busyMessage: old.busyMessage, opensURL: old.opensURL
                )
            }
        }
    }
}

/// In-memory `ProjectLaunchSource` driving the real `LiveProjectsSource`:
/// two checkouts (`api` with a board, `web` with `scripts/app.sh`), fake
/// pids, scripted board answers. Never spawns, never probes ports.
final class FakeLaunchSource: ProjectLaunchSource, @unchecked Sendable {
    var runningURL: URL?
    var upResult: HarnessDashboardOutcome = .failed
    var upCount = 0
    var spawned: [[String]] = []
    var opened: [URL] = []
    var alivePids: Set<Int32> = []
    var nextPid: Int32 = 1000
    var dashboardTOML: [String: String] = [:]

    func devEntries() -> [ProjectDevEntry] {
        [ProjectDevEntry(name: "api", rootPath: "/dev/api", modifiedAt: Date(timeIntervalSince1970: 200)),
         ProjectDevEntry(name: "web", rootPath: "/dev/web", modifiedAt: Date(timeIntervalSince1970: 100))]
    }

    func fileExists(atPath path: String) -> Bool {
        path == "/dev/api/scripts/dashboard.py" || path == "/dev/web/scripts/app.sh"
            || dashboardTOML[path] != nil
    }

    func fileContents(atPath path: String) -> Data? { dashboardTOML[path]?.data(using: .utf8) }

    func spawn(command: [String], workingDirectory: String, logPath: String) -> Int32? {
        spawned.append(command)
        nextPid += 1
        alivePids.insert(nextPid)
        return nextPid
    }

    func isPidAlive(_ pid: Int32) -> Bool { alivePids.contains(pid) }

    func terminate(_ pid: Int32) {}

    func kill(_ pid: Int32) { alivePids.remove(pid) }

    func runningBoardURL(rootPath: String) async -> URL? { runningURL }

    func boardUp(rootPath: String) async -> HarnessDashboardOutcome {
        upCount += 1
        return upResult
    }

    func boardDown(rootPath: String) async {}

    func open(_ url: URL) async { opened.append(url) }

    func logDirectory() -> URL { URL(fileURLWithPath: "/tmp/ccp-projects-widget-tests/logs") }

    func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
}
