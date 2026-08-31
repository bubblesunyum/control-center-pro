// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Combine
import Foundation

// MARK: - Public restatements of upstream clipboard types

public enum BridgedClipboardEntryKind: String, Sendable, Equatable, Codable, CaseIterable {
    case text
    case image
    case files
}

public struct BridgedClipboardEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var text: String
    public var copiedAt: Date
    public var pinnedAt: Date?
    public let kind: BridgedClipboardEntryKind
    public let filePaths: [String]
    public let imageFile: String?
    public let imageHash: String?
    public let imageWidth: Int?
    public let imageHeight: Int?

    public init(
        id: UUID = UUID(),
        text: String,
        copiedAt: Date = Date(),
        pinnedAt: Date? = nil,
        kind: BridgedClipboardEntryKind = .text,
        filePaths: [String] = [],
        imageFile: String? = nil,
        imageHash: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil
    ) {
        self.id = id
        self.text = text
        self.copiedAt = copiedAt
        self.pinnedAt = pinnedAt
        self.kind = kind
        self.filePaths = filePaths
        self.imageFile = imageFile
        self.imageHash = imageHash
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    public var isPinned: Bool { pinnedAt != nil }
}

// MARK: - Service wrapper

/// Thin visibility shim over `ClipboardHistoryService.shared`.
///
/// No policy, no storage, no branch — the adapter in `CCPKit` decides when to
/// start, what to show, and what a missing permission means. This just makes an
/// internal singleton reachable across the module boundary.
public enum BridgedClipboardHistory {
    private static var service: ClipboardHistoryService { .shared }

    public static var entries: [BridgedClipboardEntry] {
        service.entries.map { BridgedClipboardEntry(bridged: $0) }
    }

    public static var isRunning: Bool { service.isRunning }

    public static var changes: AnyPublisher<Void, Never> {
        service.objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }

    public static func syncWithPreferences() {
        service.syncWithPreferences()
    }

    public static func copy(_ entry: BridgedClipboardEntry, completion: @escaping (Bool) -> Void) {
        guard let upstream = service.entries.first(where: { $0.id == entry.id }) else {
            completion(false)
            return
        }
        service.copy(upstream, completion: completion)
    }

    public static func copy(_ entries: [BridgedClipboardEntry], completion: @escaping (Bool) -> Void) {
        let ids = Set(entries.map(\.id))
        let upstream = service.entries.filter { ids.contains($0.id) }
        guard !upstream.isEmpty else {
            completion(false)
            return
        }
        service.copy(upstream, completion: completion)
    }

    public static func togglePin(_ entry: BridgedClipboardEntry) {
        guard let upstream = service.entries.first(where: { $0.id == entry.id }) else { return }
        service.togglePin(upstream)
    }

    public static func remove(_ entry: BridgedClipboardEntry) {
        guard let upstream = service.entries.first(where: { $0.id == entry.id }) else { return }
        service.remove(upstream)
    }

    public static func clearRecent() { service.clearRecent() }
    public static func clearAll() { service.clearAll() }

    public static func filteredEntries(matching query: String) -> [BridgedClipboardEntry] {
        service.filteredEntries(matching: query).map { BridgedClipboardEntry(bridged: $0) }
    }

    public static func ensureHistoryEnabled() {
        // Only enable on first launch (no value yet) — if the user disabled
        // history in settings we must respect it. The widget itself will show
        // an inline "Enable" prompt when not running.
        if UserDefaults.standard.object(forKey: DefaultsKey.clipboardHistoryEnabled) == nil {
            UserDefaults.standard.set(true, forKey: DefaultsKey.clipboardHistoryEnabled)
        }
        service.syncWithPreferences()
    }

    public static func flushBeforeTermination() {
        service.flushBeforeTermination()
    }
}

// MARK: - Conversions

private extension BridgedClipboardEntry {
    init(bridged: ClipboardHistoryEntry) {
        self.init(
            id: bridged.id,
            text: bridged.text,
            copiedAt: bridged.copiedAt,
            pinnedAt: bridged.pinnedAt,
            kind: BridgedClipboardEntryKind(bridged: bridged.kind),
            filePaths: bridged.filePaths,
            imageFile: bridged.imageFile,
            imageHash: bridged.imageHash,
            imageWidth: bridged.imageWidth,
            imageHeight: bridged.imageHeight
        )
    }
}

private extension BridgedClipboardEntryKind {
    init(bridged: ClipboardHistoryEntryKind) {
        switch bridged {
        case .text: self = .text
        case .image: self = .image
        case .files: self = .files
        }
    }
}

private extension ClipboardHistoryEntryKind {
    init(bridged: BridgedClipboardEntryKind) {
        switch bridged {
        case .text: self = .text
        case .image: self = .image
        case .files: self = .files
        }
    }
}
