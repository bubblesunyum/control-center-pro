// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import VorssaintEngines

/// Every permission unread, which is what a fresh TCC state looks like.
func undeterminedPermissions() -> PermissionSnapshot {
    PermissionSnapshot(
        accessibility: .undetermined,
        screenRecording: .undetermined,
        fullDiskAccess: .undetermined,
        notifications: .undetermined,
        camera: .undetermined,
        microphone: .undetermined)
}

func permissions(accessibility: PermissionAuthorization) -> PermissionSnapshot {
    var snapshot = undeterminedPermissions()
    snapshot.accessibility = accessibility
    return snapshot
}

/// Stands in for TCC, which a test cannot arrange.
@MainActor
final class FakePermissionSource: PermissionSource {
    var snapshot: PermissionSnapshot
    private(set) var refreshCount = 0
    private(set) var requested: [PermissionKind] = []
    private(set) var settingsOpened: [PermissionKind] = []

    private var continuation: AsyncStream<PermissionSnapshot>.Continuation?

    init(snapshot: PermissionSnapshot = undeterminedPermissions()) {
        self.snapshot = snapshot
    }

    var updates: AsyncStream<PermissionSnapshot> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func refresh() { refreshCount += 1 }
    func request(_ kind: PermissionKind) { requested.append(kind) }
    func openSettings(for kind: PermissionKind) { settingsOpened.append(kind) }

    /// Publishes a change the way the system would, once a watcher is listening.
    func emit(_ snapshot: PermissionSnapshot) {
        self.snapshot = snapshot
        continuation?.yield(snapshot)
    }

    var isWatched: Bool { continuation != nil }
}

/// Polls until `condition` holds, reporting whether it ever did.
///
/// A change travels the adapter's stream across a task boundary, so it cannot
/// be observed on the next line. Returns the answer rather than asserting it:
/// the tests here need both directions — that an update arrives, and that after
/// `deactivate()` none does — and a helper that failed on timeout could not
/// express the second.
///
/// One second, sampled every 5ms: long enough that a loaded machine will not
/// flake, short enough that the negative case does not dominate the suite.
@MainActor
func becomesTrue(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
