// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Combine
import Foundation
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

    private let subject = PassthroughSubject<Void, Never>()
    /// How many subscriptions are live, so a test can assert the panel stops
    /// observing rather than merely stops reacting.
    ///
    /// Counted behind a lock rather than on the main actor: a subscription is
    /// cancelled by ARC releasing it, which can happen on whatever thread drops
    /// the last reference, and a fake that trapped there would be reporting a
    /// fault of its own making.
    var observerCount: Int { lock.withLock { observers } }

    private let lock = NSLock()
    private nonisolated(unsafe) var observers = 0

    /// Whether `refresh()` publishes its result on a later turn, the way the
    /// engine does — every field upstream writes goes through a main-queue hop
    /// even when it is already on the main thread.
    var refreshLandsLater = false
    var refreshedSnapshot: PermissionSnapshot?

    init(snapshot: PermissionSnapshot = undeterminedPermissions()) {
        self.snapshot = snapshot
    }

    var changes: AnyPublisher<Void, Never> {
        subject
            .handleEvents(
                receiveSubscription: { [lock] _ in lock.withLock { self.observers += 1 } },
                receiveCancel: { [lock] in lock.withLock { self.observers -= 1 } })
            .eraseToAnyPublisher()
    }

    func refresh() {
        refreshCount += 1
        guard refreshLandsLater, let refreshed = refreshedSnapshot else { return }
        DispatchQueue.main.async { self.snapshot = refreshed }
    }
    func request(_ kind: PermissionKind) { requested.append(kind) }
    func openSettings(for kind: PermissionKind) { settingsOpened.append(kind) }

    /// Publishes a change the way the system would: the new state is in place
    /// only after the emission, matching the engine's willSet ordering.
    func emit(_ snapshot: PermissionSnapshot) {
        subject.send(())
        self.snapshot = snapshot
    }
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
