// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Combine
import Foundation
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
    @ObservationIgnored private var observation: AnyCancellable?

    public convenience init() {
        self.init(source: SystemPermissionSource())
    }

    public init(source: PermissionSource) {
        self.source = source
        self.snapshot = source.snapshot
    }


    public func activate() {
        guard observation == nil else { return }
        source.refresh()
        snapshot = source.snapshot
        observation = source.changes.sink { [weak self] in
            // The engine emits in willSet, before its storage is updated, so
            // the new values are only in place on the next turn.
            DispatchQueue.main.async { self?.readSnapshot() }
        }
        // `refresh()` schedules its writes rather than making them, so the read
        // above sees the state as it was when the panel last closed. The main
        // queue is FIFO, so re-reading behind those writes is what actually
        // shows a permission granted while the panel was shut.
        DispatchQueue.main.async { [weak self] in self?.readSnapshot() }
    }

    /// Cancels synchronously: idle CPU with the panel shut is a feature, and a
    /// teardown that only takes effect at the next permission change would
    /// leave an observation running against it for as long as nothing changed.
    public func deactivate() {
        observation?.cancel()
        observation = nil
    }

    private func readSnapshot() {
        guard observation != nil else { return }
        snapshot = source.snapshot
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
