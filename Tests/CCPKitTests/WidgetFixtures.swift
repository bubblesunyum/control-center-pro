// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import SwiftUI
@testable import CCPKit

/// A widget that does nothing but exist, so registry tests can talk about
/// registration and lookup without dragging an engine in.
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

    func activate() { activations += 1 }
    func deactivate() { deactivations += 1 }
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
