// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import VorssaintEngines
import XCTest

@MainActor
final class PermissionsAdapterTests: XCTestCase {
    func testReportsGrantedAsGranted() {
        let adapter = PermissionsAdapter(
            source: FakePermissionSource(snapshot: permissions(accessibility: .granted)))
        XCTAssertEqual(adapter.state(of: .accessibility), .granted)
    }

    func testReportsDeniedAsDenied() {
        let adapter = PermissionsAdapter(
            source: FakePermissionSource(snapshot: permissions(accessibility: .denied)))
        XCTAssertEqual(adapter.state(of: .accessibility), .denied)
    }

    func testReportsUnaskedAsUndetermined() {
        let adapter = PermissionsAdapter(source: FakePermissionSource())
        XCTAssertEqual(adapter.state(of: .accessibility), .undetermined)
    }

    /// macOS exposes no read for audio capture, so the adapter must say it
    /// cannot tell rather than reporting a denial it did not observe.
    func testUnreadablePermissionIsIndeterminate() {
        let adapter = PermissionsAdapter(source: FakePermissionSource())
        XCTAssertEqual(adapter.state(of: .audioCapture), .indeterminate)
    }

    // MARK: - The inline grant state

    func testDeniedPermissionIsUnmet() {
        let adapter = PermissionsAdapter(
            source: FakePermissionSource(snapshot: permissions(accessibility: .denied)))
        XCTAssertEqual(adapter.unmet(in: [.accessibility]), [.accessibility])
    }

    func testGrantedPermissionIsMet() {
        let adapter = PermissionsAdapter(
            source: FakePermissionSource(snapshot: permissions(accessibility: .granted)))
        XCTAssertTrue(adapter.unmet(in: [.accessibility]).isEmpty)
    }

    /// A widget must not be walled off behind a prompt for a permission the
    /// system will not report on — it may well already be granted.
    func testUnreadablePermissionDoesNotBlockTheWidget() {
        let adapter = PermissionsAdapter(source: FakePermissionSource())
        XCTAssertTrue(adapter.unmet(in: [.audioCapture]).isEmpty)
    }

    func testUnmetNamesOnlyTheMissingOne() {
        let adapter = PermissionsAdapter(
            source: FakePermissionSource(snapshot: permissions(accessibility: .denied)))
        XCTAssertEqual(adapter.unmet(in: [.accessibility, .audioCapture]), [.accessibility])
    }

    func testWidgetNeedingNothingIsNeverBlocked() {
        let adapter = PermissionsAdapter(source: FakePermissionSource())
        XCTAssertTrue(adapter.unmet(in: []).isEmpty)
    }

    // MARK: - Lifecycle

    func testActivateRefreshesSoAGrantMadeWhileShutIsSeen() {
        let source = FakePermissionSource()
        let adapter = PermissionsAdapter(source: source)
        source.snapshot = permissions(accessibility: .granted)

        adapter.activate()

        XCTAssertEqual(source.refreshCount, 1)
        XCTAssertEqual(adapter.state(of: .accessibility), .granted)
    }

    func testActivateIsIdempotent() {
        let source = FakePermissionSource()
        let adapter = PermissionsAdapter(source: source)
        adapter.activate()
        adapter.activate()
        XCTAssertEqual(source.refreshCount, 1)
    }

    func testGrantWhileOpenReachesTheAdapter() async {
        let source = FakePermissionSource()
        let adapter = PermissionsAdapter(source: source)
        adapter.activate()

        source.emit(permissions(accessibility: .granted))

        let arrived = await becomesTrue { adapter.state(of: .accessibility) == .granted }
        XCTAssertTrue(arrived, "a grant made while the panel was open never reached the adapter")
    }

    func testDeactivateStopsWatching() async {
        let source = FakePermissionSource()
        let adapter = PermissionsAdapter(source: source)
        adapter.activate()
        adapter.deactivate()

        source.emit(permissions(accessibility: .granted))

        let arrived = await becomesTrue { adapter.state(of: .accessibility) == .granted }
        XCTAssertFalse(arrived, "a deactivated adapter kept listening")
    }

    func testDeactivateThenActivateWatchesAgain() {
        let source = FakePermissionSource()
        let adapter = PermissionsAdapter(source: source)
        adapter.activate()
        adapter.deactivate()
        adapter.activate()
        XCTAssertEqual(source.refreshCount, 2)
    }

    // MARK: - Carrying the request

    func testRequestAsksForTheWidgetsPermission() {
        let source = FakePermissionSource()
        let adapter = PermissionsAdapter(source: source)
        adapter.request(.accessibility)
        XCTAssertEqual(source.requested, [.accessibility])
    }

    func testOpenSettingsRoutesToTheRightPane() {
        let source = FakePermissionSource()
        let adapter = PermissionsAdapter(source: source)
        adapter.openSettings(for: .audioCapture)
        XCTAssertEqual(source.settingsOpened, [.audioCapture])
    }
}
