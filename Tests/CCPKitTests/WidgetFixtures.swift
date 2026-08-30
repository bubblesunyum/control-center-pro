// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI
@testable import CCPKit

/// A widget that does nothing but exist, so registry tests can talk about
/// registration and lookup without dragging an engine in.
///
/// It keeps its own tally *and* writes to the shared ``WidgetLifecycleLog``
/// because the two answer different questions: the tally says whether this
/// object got the call, and the log says whether the panel started the widgets
/// it placed — which is asked of instances the registry built and no test
/// holds a reference to.
@MainActor
final class StubWidget: CCPWidget {
    static let descriptor = WidgetDescriptor(
        id: "stub",
        title: "Stub",
        symbolName: "circle"
    )

    private(set) var activations = 0
    private(set) var deactivations = 0

    func makeView() -> some View { Text(verbatim: "stub") }

    func activate() {
        activations += 1
        WidgetLifecycleLog.shared.activated.append(id)
    }

    func deactivate() {
        deactivations += 1
        WidgetLifecycleLog.shared.deactivated.append(id)
    }
}

/// What the stub widgets were told to do, in order.
///
/// A registry hands back type-erased instances it made itself, so a test that
/// asks the panel to start its widgets has nothing to interrogate afterwards.
/// Reset it at the top of any test that reads it.
@MainActor
final class WidgetLifecycleLog {
    static let shared = WidgetLifecycleLog()

    var activated: [WidgetID] = []
    var deactivated: [WidgetID] = []

    func reset() {
        activated = []
        deactivated = []
    }
}

/// A second kind, for the cases that only mean something with more than one:
/// ordering, lookup by id, replacing a registration.
@MainActor
final class OtherStubWidget: CCPWidget {
    static let descriptor = WidgetDescriptor(
        id: "other-stub",
        title: "Other Stub",
        symbolName: "square",
        size: .tall,
        permissions: [.audioCapture]
    )

    func makeView() -> some View { Text(verbatim: "other") }

    func activate() { WidgetLifecycleLog.shared.activated.append(id) }
    func deactivate() { WidgetLifecycleLog.shared.deactivated.append(id) }
}

/// Same id as `StubWidget`, different everything else — the collision a
/// re-registration has to resolve.
@MainActor
final class RenamedStubWidget: CCPWidget {
    static let descriptor = WidgetDescriptor(
        id: StubWidget.descriptor.id,
        title: "Renamed Stub",
        symbolName: "triangle"
    )

    func makeView() -> some View { Text(verbatim: "renamed") }
}

@MainActor
func stubRegistry() -> WidgetRegistry {
    let registry = WidgetRegistry()
    registry.register(StubWidget.self)
    registry.register(OtherStubWidget.self)
    return registry
}
