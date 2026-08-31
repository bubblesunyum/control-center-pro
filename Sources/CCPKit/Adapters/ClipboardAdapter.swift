// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Combine
import Foundation
import Observation
import VorssaintEngines

// MARK: - Public snapshot

public enum ClipboardEntryKind: String, Sendable, Equatable, Codable, CaseIterable {
    case text
    case image
    case files
}

public struct ClipboardEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var text: String
    public var copiedAt: Date
    public var pinnedAt: Date?
    public let kind: ClipboardEntryKind
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
        kind: ClipboardEntryKind = .text,
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

    public var preview: String {
        switch kind {
        case .text:
            let prefix = text.prefix(2_000)
            let collapsed = prefix
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let visible = collapsed.isEmpty ? String(prefix) : collapsed
            return prefix.endIndex == text.endIndex ? visible : visible + "…"
        case .image:
            guard let w = imageWidth, let h = imageHeight else { return "Image" }
            return "\(w)×\(h)"
        case .files:
            let names = filePaths.map { ($0 as NSString).lastPathComponent }
            return names.joined(separator: ", ")
        }
    }
}

// MARK: - Source

/// Where clipboard history comes from.
///
/// The seam a test stands a fake in for: real pasteboard reads are not something
/// a test can arrange, and `ClipboardHistoryService` is a singleton tied to
/// `UserDefaults` and the pasteboard lane.
@MainActor
public protocol ClipboardSource: AnyObject {
    var snapshot: [ClipboardEntry] { get }
    var isRunning: Bool { get }
    var changes: AnyPublisher<Void, Never> { get }
    func ensureHistoryEnabled()
    func copy(_ entry: ClipboardEntry, completion: @escaping (Bool) -> Void)
    func togglePin(_ entry: ClipboardEntry)
    func remove(_ entry: ClipboardEntry)
    func clearRecent()
    func clearAll()
}

/// The real one, reading through the engine bridge.
@MainActor
public final class LiveClipboardSource: ClipboardSource {
    public init() {}

    public var snapshot: [ClipboardEntry] {
        BridgedClipboardHistory.entries.map { ClipboardEntry(bridged: $0) }
    }

    public var isRunning: Bool { BridgedClipboardHistory.isRunning }

    public var changes: AnyPublisher<Void, Never> { BridgedClipboardHistory.changes }

    public func ensureHistoryEnabled() {
        BridgedClipboardHistory.ensureHistoryEnabled()
    }

    public func copy(_ entry: ClipboardEntry, completion: @escaping (Bool) -> Void) {
        BridgedClipboardHistory.copy(BridgedClipboardEntry(bridging: entry), completion: completion)
    }

    public func togglePin(_ entry: ClipboardEntry) {
        BridgedClipboardHistory.togglePin(BridgedClipboardEntry(bridging: entry))
    }

    public func remove(_ entry: ClipboardEntry) {
        BridgedClipboardHistory.remove(BridgedClipboardEntry(bridging: entry))
    }

    public func clearRecent() { BridgedClipboardHistory.clearRecent() }
    public func clearAll() { BridgedClipboardHistory.clearAll() }
}

// MARK: - Adapter

/// The widget's model: observes history while the panel is open and keeps it
/// warm while shut so entries are there when the panel opens.
///
/// This is the first widget that opts out of the "idle CPU with panel shut is
/// a feature" rule: sampling must continue in background so the history the
/// widget shows is not empty. `deactivate()` therefore keeps observing; only
/// removal of the widget stops it.
@MainActor
@Observable
public final class ClipboardAdapter {
    public private(set) var entries: [ClipboardEntry]
    public private(set) var isHistoryEnabled: Bool

    @ObservationIgnored private let source: ClipboardSource
    @ObservationIgnored private var observation: AnyCancellable?
    @ObservationIgnored private var isActive = false

    public convenience init() {
        self.init(source: LiveClipboardSource())
    }

    public init(source: ClipboardSource) {
        self.source = source
        self.entries = source.snapshot
        self.isHistoryEnabled = source.isRunning
        // History must already be warm even before the first panel open — a
        // copy made while the panel is shut is exactly the one the widget will
        // show next time it opens.
        source.ensureHistoryEnabled()
        self.isHistoryEnabled = source.isRunning
        // Start observing immediately so background copies land in `entries`
        // without waiting for the first `activate()`.
        observe()
    }

    /// Start observing. Idempotent — a second open while already open does not
    /// stack a second subscription.
    public func activate() {
        guard !isActive else { return }
        isActive = true
        // Re-read in case `ensureHistoryEnabled` just started the timer and the
        // publisher hasn't fired yet.
        entries = source.snapshot
        isHistoryEnabled = source.isRunning
        if observation == nil { observe() }
    }

    /// Stop observing — but clipboard keeps its poll alive in background so
    /// history populates while the panel is shut. This only flips the
    /// active flag; the subscription stays.
    public func deactivate() {
        guard isActive else { return }
        isActive = false
        // Intentionally does not cancel `observation`: background sampling is the
        // feature. The panel being shut must not stop the timer.
    }

    /// Fully stop — called when the widget is removed from the panel, not when
    /// the panel shuts. A removed widget that kept sampling would be the leak
    /// the lifecycle exists to prevent.
    public func stop() {
        isActive = false
        observation?.cancel()
        observation = nil
    }

    var isObserving: Bool { observation != nil }

    public func enableHistory() {
        source.ensureHistoryEnabled()
        entries = source.snapshot
        isHistoryEnabled = source.isRunning
    }

    public func copy(_ entry: ClipboardEntry, completion: ((Bool) -> Void)? = nil) {
        source.copy(entry) { success in
            Task { @MainActor in completion?(success) }
        }
    }

    public func togglePin(_ entry: ClipboardEntry) {
        source.togglePin(entry)
        // Optimistic: engine will fire `changes` and `entries` will re-read, but
        // update now for snappy UI.
        entries = source.snapshot
    }

    public func remove(_ entry: ClipboardEntry) {
        source.remove(entry)
        entries = source.snapshot
    }

    public func clearRecent() {
        source.clearRecent()
        entries = source.snapshot
    }

    public func clearAll() {
        source.clearAll()
        entries = source.snapshot
    }

    private func observe() {
        guard observation == nil else { return }
        // The engine publishes in willSet, before storage is updated, so the new
        // values are only in place on the next turn.
        observation = source.changes.sink { [weak self] in
            Task { @MainActor [weak self] in self?.readSnapshot() }
        }
        // Re-read behind any writes the engine scheduled but hasn't flushed.
        Task { @MainActor [weak self] in self?.readSnapshot() }
    }

    private func readSnapshot() {
        guard observation != nil else { return }
        entries = source.snapshot
        isHistoryEnabled = source.isRunning
    }
}

// MARK: - Conversions

private extension ClipboardEntry {
    init(bridged: BridgedClipboardEntry) {
        self.init(
            id: bridged.id,
            text: bridged.text,
            copiedAt: bridged.copiedAt,
            pinnedAt: bridged.pinnedAt,
            kind: ClipboardEntryKind(bridged: bridged.kind),
            filePaths: bridged.filePaths,
            imageFile: bridged.imageFile,
            imageHash: bridged.imageHash,
            imageWidth: bridged.imageWidth,
            imageHeight: bridged.imageHeight
        )
    }
}

private extension BridgedClipboardEntry {
    init(bridging entry: ClipboardEntry) {
        self.init(
            id: entry.id,
            text: entry.text,
            copiedAt: entry.copiedAt,
            pinnedAt: entry.pinnedAt,
            kind: BridgedClipboardEntryKind(bridging: entry.kind),
            filePaths: entry.filePaths,
            imageFile: entry.imageFile,
            imageHash: entry.imageHash,
            imageWidth: entry.imageWidth,
            imageHeight: entry.imageHeight
        )
    }
}

private extension ClipboardEntryKind {
    init(bridged: BridgedClipboardEntryKind) {
        switch bridged {
        case .text: self = .text
        case .image: self = .image
        case .files: self = .files
        }
    }
}

private extension BridgedClipboardEntryKind {
    init(bridging kind: ClipboardEntryKind) {
        switch kind {
        case .text: self = .text
        case .image: self = .image
        case .files: self = .files
        }
    }
}
