// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import Observation

public struct WebsiteEntry: Codable, Hashable, Sendable {
    public var id: WidgetID
    public var url: String
    public var originalURL: String
    public var lastReloadedAt: Date

    public init(id: WidgetID, url: String, originalURL: String, lastReloadedAt: Date) {
        self.id = id
        self.url = url
        self.originalURL = originalURL
        self.lastReloadedAt = lastReloadedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case url
        case originalURL
        case lastReloadedAt
    }
}

@MainActor
@Observable
public final class WebsiteStore {
    public static let shared = WebsiteStore()
    public static let staleInterval: TimeInterval = 3600

    public private(set) var entries: [WebsiteEntry] = []

    @ObservationIgnored private let file: JSONFileStore<[WebsiteEntry]>

    public init(file: JSONFileStore<[WebsiteEntry]> = JSONFileStore(filename: "websites.json", default: [])) {
        self.file = file
        self.entries = file.tolerantLoad()
    }

    public func entry(for id: WidgetID) -> WebsiteEntry? {
        entries.first { $0.id == id }
    }

    @discardableResult
    public func add(url: String) -> WidgetID {
        let normalized = Self.normalizedURL(url)
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let id = WidgetID("website-\(suffix)")
        entries.append(WebsiteEntry(id: id, url: normalized, originalURL: normalized, lastReloadedAt: Date()))
        persist()
        return id
    }

    public func updateURL(_ id: WidgetID, to url: String) {
        let normalized = Self.normalizedURL(url)
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            entries.append(WebsiteEntry(id: id, url: normalized, originalURL: normalized, lastReloadedAt: .distantPast))
            persist()
            return
        }
        var entry = entries[index]
        entry.url = normalized
        entries[index] = entry
        persist()
    }

    public func resetToOriginal(_ id: WidgetID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries[index]
        entry.url = entry.originalURL
        entries[index] = entry
        persist()
    }

    public func remove(_ id: WidgetID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    public func markReloaded(_ id: WidgetID, at date: Date = Date()) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries[index]
        entry.lastReloadedAt = date
        entries[index] = entry
        persist()
    }

    public func shouldReload(_ id: WidgetID, at date: Date = Date()) -> Bool {
        guard let entry = entry(for: id) else { return false }
        return date.timeIntervalSince(entry.lastReloadedAt) >= Self.staleInterval
    }

    public static func normalizedURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+\-.]*://"#, options: .regularExpression) != nil {
            return trimmed
        }
        return "https://" + trimmed
    }

    private func persist() {
        try? file.save(entries)
    }
}

public extension WidgetID {
    var isWebsiteTemplate: Bool { rawValue == "website" }
    var isWebsiteInstance: Bool { rawValue.hasPrefix("website-") }
    var isWebsite: Bool { isWebsiteTemplate || isWebsiteInstance }
}
