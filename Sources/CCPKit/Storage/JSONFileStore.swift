// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// One Codable value, kept as JSON in Application Support.
///
/// Reading is total: a file that isn't there yet and a file that can't be
/// parsed both come back as the default, because neither is a reason to keep
/// the panel from opening. A file that can't be parsed is moved aside rather
/// than overwritten — resetting someone's arrangement is bad enough without
/// destroying the evidence of why.
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
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            setAside()
            return defaultValue
        }
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func setAside() {
        let spoiled = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: spoiled)
        try? FileManager.default.moveItem(at: url, to: spoiled)
    }
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
