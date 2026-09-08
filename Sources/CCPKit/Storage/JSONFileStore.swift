// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// One Codable value, kept as JSON in Application Support.
///
/// Reading is total and non-destructive: a file that isn't there yet and a
/// file that can't be parsed both come back as the default, because neither
/// is a reason to keep the panel from opening — and neither is a reason to
/// destroy evidence. A read never moves anything aside. The first deliberate
/// write over bytes we cannot read sets them aside instead, once only, so
/// resetting someone's arrangement is never also destroying the explanation
/// of why.
public struct JSONFileStore<Value: Codable & Sendable>: Sendable {
    public let url: URL
    private let defaultValue: Value

    /// - Parameter directory: where the file lives. Defaults to the app's own
    ///   folder in Application Support; tests hand it a temporary one.
    public init(
        filename: String,
        default defaultValue: Value,
        in directory: URL = .applicationSupport
    ) {
        url = directory.appendingPathComponent(filename)
        self.defaultValue = defaultValue
    }

    public func load() -> Value {
        guard let data = try? Data(contentsOf: url) else { return defaultValue }
        if let decoded = try? JSONDecoder().decode(Value.self, from: data) {
            return decoded
        }
        return rescued() ?? defaultValue
    }

    /// A previous set-aside that still decodes, standing in for live bytes we
    /// cannot read. Only consulted when the live file exists but fails — a
    /// missing live file is a fresh start, not a resurrection. Adopted as live
    /// state; the next save re-commits it, which is what makes a recovery
    /// survive quitting rather than living only in memory.
    private func rescued() -> Value? {
        guard let data = try? Data(contentsOf: corruptURL),
              let decoded = try? JSONDecoder().decode(Value.self, from: data)
        else { return nil }
        return decoded
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        setAsideUndecodableLiveFile()
        try data.write(to: url, options: .atomic)
    }

    /// The first deliberate write over bytes we cannot read moves them aside
    /// as evidence. Once-only: an existing `.corrupt` is never overwritten,
    /// and a live file that already decodes is left alone. This lives on the
    /// write because the store cannot remember a failed read — and because a
    /// write is the one operation that knows someone is behind it.
    private func setAsideUndecodableLiveFile() {
        guard !FileManager.default.fileExists(atPath: corruptURL.path),
              let data = try? Data(contentsOf: url),
              (try? JSONDecoder().decode(Value.self, from: data)) == nil
        else { return }
        try? FileManager.default.moveItem(at: url, to: corruptURL)
    }

    private var corruptURL: URL { url.appendingPathExtension("corrupt") }

    /// Per-item lenient decode for array stores: one bad element no longer
    /// costs the whole file. Falls back to `load()` — the default, or a
    /// rescue — when nothing salvages, leaving the file for the next save to
    /// set aside.
    public func tolerantLoad<Element>() -> [Element] where Value == [Element], Element: Codable {
        guard let data = try? Data(contentsOf: url) else { return load() }
        if let decoded = try? JSONDecoder().decode([Element].self, from: data) {
            return decoded
        }
        if let wrapped = try? JSONDecoder().decode([FailableElement<Element>].self, from: data) {
            let salvaged = wrapped.compactMap(\.element)
            if !wrapped.isEmpty, !salvaged.isEmpty {
                return salvaged
            }
        }
        return load()
    }
}

/// One leniently-decoded array element: a single bad item decodes to nil
/// instead of failing the whole array. File scope because Swift forbids
/// nesting a type inside a generic function.
private struct FailableElement<Element: Decodable>: Decodable {
    let element: Element?
    init(from decoder: Decoder) throws { element = try? Element(from: decoder) }
}

public extension URL {
    /// The app's own folder under Application Support.
    ///
    /// `Bundle.main.bundleIdentifier` is nil under `swift run` and under the
    /// test runner it belongs to someone else, so the shipped id is the
    /// fallback — a debug run and the built app then read the same files,
    /// which is what you want when the thing you are debugging is persistence.
    static let applicationSupport: URL = {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return root.appendingPathComponent("com.controlcenterpro.ControlCenterPro")
    }()
}
