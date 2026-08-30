// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Observation
import VorssaintEngines

/// What the panel knows about one permission.
///
/// CCP's own vocabulary rather than the engine's, so a widget never names an
/// upstream type to ask whether it may run.
public enum PermissionState: Sendable, Equatable {
    case granted
    case denied
    /// Never asked. The system will show its own prompt when we do.
    case undetermined
    /// macOS offers no way to read this one; the widget should try and let the
    /// failure speak rather than block itself on a guess.
    case indeterminate
}

/// Answers whether a widget may run, and carries the request when it may not.
///
/// Follows the widget lifecycle: `activate()` when the panel opens and
/// `deactivate()` when it closes, so a shut panel watches nothing.
@MainActor
@Observable
public final class PermissionsAdapter {
    public private(set) var snapshot: PermissionSnapshot

    @ObservationIgnored private let source: PermissionSource
    // nonisolated(unsafe): written only on MainActor, cancelled from deinit which is non-isolated.
    @ObservationIgnored private nonisolated(unsafe) var watch: Task<Void, Never>?

    public convenience init() {
        self.init(source: SystemPermissionSource())
    }

    public init(source: PermissionSource) {
        self.source = source
        self.snapshot = source.snapshot
    }

    deinit { watch?.cancel() }

    public func activate() {
        guard watch == nil else { return }
        source.refresh()
        snapshot = source.snapshot
        let updates = source.updates
        watch = Task { @MainActor [weak self] in
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                self?.snapshot = snapshot
            }
        }
    }

    public func deactivate() {
        watch?.cancel()
        watch = nil
    }

    public func state(of permission: WidgetPermission) -> PermissionState {
        switch snapshot[Self.kind(of: permission)] {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        case .unknown: return .indeterminate
        }
    }

    /// The permissions standing between a widget and running, which is what its
    /// inline grant state is drawn from. Empty means it can draw itself.
    ///
    /// A permission we cannot read does not appear here: refusing to run on a
    /// state macOS will not tell us would leave the widget permanently stuck
    /// behind a prompt the user has possibly already satisfied.
    public func unmet(in permissions: Set<WidgetPermission>) -> Set<WidgetPermission> {
        permissions.filter { permission in
            switch state(of: permission) {
            case .granted, .indeterminate: return false
            case .denied, .undetermined: return true
            }
        }
    }

    /// Prompts where the system has a prompt, and otherwise opens the pane
    /// where the user can grant it by hand.
    public func request(_ permission: WidgetPermission) {
        source.request(Self.kind(of: permission))
    }

    public func openSettings(for permission: WidgetPermission) {
        source.openSettings(for: Self.kind(of: permission))
    }

    private static func kind(of permission: WidgetPermission) -> PermissionKind {
        switch permission {
        case .audioCapture: return .audioCapture
        case .accessibility: return .accessibility
        }
    }
}
