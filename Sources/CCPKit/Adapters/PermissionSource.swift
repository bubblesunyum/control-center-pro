// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import VorssaintEngines

/// Where permission answers come from.
///
/// The seam a test stands a fake in for: real TCC state is not something a test
/// can arrange, so nothing above this protocol talks to the system directly.
@MainActor
public protocol PermissionSource: AnyObject {
    var snapshot: PermissionSnapshot { get }
    /// A stream of snapshots, one per change the system reports.
    var updates: AsyncStream<PermissionSnapshot> { get }
    func refresh()
    func request(_ kind: PermissionKind)
    func openSettings(for kind: PermissionKind)
}

/// The real one, reading through the engine bridge.
@MainActor
public final class SystemPermissionSource: PermissionSource {
    public init() {}

    public var snapshot: PermissionSnapshot { SystemPermissions.snapshot }
    public var updates: AsyncStream<PermissionSnapshot> { SystemPermissions.updates }
    public func refresh() { SystemPermissions.refresh() }
    public func request(_ kind: PermissionKind) { SystemPermissions.request(kind) }
    public func openSettings(for kind: PermissionKind) { SystemPermissions.openSettings(for: kind) }
}
