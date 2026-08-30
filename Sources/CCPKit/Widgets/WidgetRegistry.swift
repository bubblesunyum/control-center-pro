// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

/// Every widget the app can offer, in the order a gallery should list them.
///
/// The registry is the only place that knows the concrete widget types: the
/// shell asks it what exists and asks it to build one, so lanes, the gallery,
/// and the persisted layout all deal in `WidgetID` alone. The app composes the
/// registry at launch rather than a shared instance assembling itself, so a
/// test can stand up a registry of fixtures without disturbing the real set.
@MainActor
public final class WidgetRegistry {
    private struct Entry {
        let descriptor: WidgetDescriptor
        let makeInstance: @MainActor () -> WidgetInstance
    }

    private var entries: [Entry] = []

    public init() {}

    /// Registering an id that is already present replaces it where it stands,
    /// so the gallery's order is the order widgets were first declared in and
    /// doesn't shuffle because one of them was overridden.
    public func register<W: CCPWidget>(_ type: W.Type) {
        let entry = Entry(descriptor: W.descriptor, makeInstance: { WidgetInstance(W()) })
        if let existing = entries.firstIndex(where: { $0.descriptor.id == W.descriptor.id }) {
            entries[existing] = entry
        } else {
            entries.append(entry)
        }
    }

    public var descriptors: [WidgetDescriptor] {
        entries.map(\.descriptor)
    }

    public func descriptor(for id: WidgetID) -> WidgetDescriptor? {
        entry(for: id)?.descriptor
    }

    /// A fresh instance of the widget, or `nil` when the id names a widget this
    /// build doesn't have — a layout written by a newer version, or by one with
    /// a widget since renamed. The caller drops the entry and keeps the rest of
    /// the arrangement.
    public func makeInstance(of id: WidgetID) -> WidgetInstance? {
        entry(for: id)?.makeInstance()
    }

    private func entry(for id: WidgetID) -> Entry? {
        entries.first { $0.descriptor.id == id }
    }
}
