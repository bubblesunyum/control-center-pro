// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

// MARK: - Retention

/// How long each note keeps text that nobody edits. The check runs only
/// when the widget loads, against the stored edit dates, so the feature needs
/// no timer at all. Pulled from Vorssaint's NotesSupport — same interval
/// values, same stored key, so a document written by the floating note reads
/// correctly here and vice-versa.
public enum NoteRetention: String, CaseIterable, Sendable {
    case never
    case day
    case week
    case month

    /// Seconds the text may sit unedited before it clears; nil keeps forever.
    public var maxIdleInterval: TimeInterval? {
        switch self {
        case .never: return nil
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        }
    }

    public static func sanitized(_ rawValue: String?) -> NoteRetention {
        guard let rawValue, let retention = NoteRetention(rawValue: rawValue) else {
            return .never
        }
        return retention
    }
}

// MARK: - Note & Document

public struct Note: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var text: String
    public var modifiedAt: Date?

    public init(id: UUID = UUID(), name: String, text: String, modifiedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.text = text
        self.modifiedAt = modifiedAt
    }
}

/// The whole notes state travels as one small document. Stable ids keep
/// selection independent from names, while array order is the tab order.
public struct NotesDocument: Codable, Equatable, Sendable {
    public static let maximumNoteCount = 12
    public static let maximumNameLength = 40

    public var notes: [Note]
    public var selectedID: UUID

    /// The stored key is `pads`, and it stays `pads` however the feature is
    /// named in Swift: the bytes are shared with upstream's floating pad, and
    /// renaming the property alone silently stops decoding every note the user
    /// already has. That is not hypothetical — it happened.
    private enum CodingKeys: String, CodingKey {
        case notes = "pads"
        case selectedID
    }

    /// One build wrote the property name out as `notes`. Read that back too,
    /// rather than treating those documents as corrupt.
    private enum LegacyCodingKeys: String, CodingKey {
        case notes
    }

    public init(notes: [Note], selectedID: UUID) {
        self.notes = notes
        self.selectedID = selectedID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedID = try container.decode(UUID.self, forKey: .selectedID)
        if let pads = try container.decodeIfPresent([Note].self, forKey: .notes) {
            notes = pads
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            notes = try legacy.decode([Note].self, forKey: .notes)
        }
    }

    public static func initial(defaultName: String,
                               id: UUID = UUID(),
                               text: String = "",
                               modifiedAt: Date? = nil) -> NotesDocument {
        let name = NotesSupport.nextNoteName(defaultName: defaultName, existingNames: [])
        let note = Note(id: id, name: name, text: text, modifiedAt: text.isEmpty ? nil : modifiedAt)
        return NotesDocument(notes: [note], selectedID: note.id)
    }

    public static func decoded(_ data: Data?, defaultName: String) -> NotesDocument? {
        guard let data,
              let decoded = try? JSONDecoder().decode(NotesDocument.self, from: data)
        else { return nil }
        return decoded.sanitized(defaultName: defaultName)
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public func sanitized(defaultName: String) -> NotesDocument {
        var seen = Set<UUID>()
        var cleanPads: [Note] = []
        for note in notes.prefix(Self.maximumNoteCount) where seen.insert(note.id).inserted {
            let fallback = NotesSupport.nextNoteName(defaultName: defaultName,
                                                         existingNames: cleanPads.map(\.name))
            let name = NotesSupport.sanitizedNoteName(note.name)
            cleanPads.append(Note(id: note.id,
                                           name: name.isEmpty ? fallback : name,
                                           text: note.text,
                                           modifiedAt: note.text.isEmpty ? nil : note.modifiedAt))
        }
        guard !cleanPads.isEmpty else { return .initial(defaultName: defaultName) }
        let selection = cleanPads.contains(where: { $0.id == selectedID }) ? selectedID : cleanPads[0].id
        return NotesDocument(notes: cleanPads, selectedID: selection)
    }

    public func addingNote(defaultName: String, id: UUID = UUID()) -> NotesDocument? {
        guard notes.count < Self.maximumNoteCount else { return nil }
        var next = self
        let name = NotesSupport.nextNoteName(defaultName: defaultName, existingNames: notes.map(\.name))
        next.notes.append(Note(id: id, name: name, text: "", modifiedAt: nil))
        next.selectedID = id
        return next
    }

    public func selecting(_ id: UUID) -> NotesDocument? {
        guard notes.contains(where: { $0.id == id }) else { return nil }
        var next = self
        next.selectedID = id
        return next
    }

    public func renaming(_ id: UUID, to proposedName: String) -> NotesDocument? {
        let name = NotesSupport.sanitizedNoteName(proposedName)
        guard !name.isEmpty, let index = notes.firstIndex(where: { $0.id == id }) else { return nil }
        var next = self
        next.notes[index].name = name
        return next
    }

    public func removing(_ id: UUID) -> NotesDocument? {
        guard notes.count > 1, let index = notes.firstIndex(where: { $0.id == id }) else { return nil }
        var next = self
        next.notes.remove(at: index)
        if selectedID == id {
            next.selectedID = next.notes[min(index, next.notes.count - 1)].id
        }
        return next
    }

    public mutating func updateSelectedText(_ text: String, modifiedAt: Date) {
        guard let index = notes.firstIndex(where: { $0.id == selectedID }),
              notes[index].text != text else { return }
        notes[index].text = text
        notes[index].modifiedAt = text.isEmpty ? nil : modifiedAt
    }

    public mutating func applyRetention(_ retention: NoteRetention, now: Date) {
        for index in notes.indices where NotesSupport.shouldClear(
            lastEdited: notes[index].modifiedAt, now: now, retention: retention
        ) {
            notes[index].text = ""
            notes[index].modifiedAt = nil
        }
    }
}

// MARK: - Support

public enum NotesSupport {
    public static func sanitizedNoteName(_ name: String) -> String {
        let words = name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return String(words.joined(separator: " ").prefix(NotesDocument.maximumNameLength))
    }

    public static func nextNoteName(defaultName: String, existingNames: [String]) -> String {
        let base = sanitizedNoteName(defaultName)
        let safeBase = base.isEmpty ? "Note" : base
        let used = Set(existingNames)
        let firstName = "\(safeBase) 1"
        guard used.contains(safeBase) || used.contains(firstName) else { return firstName }
        for number in 2...NotesDocument.maximumNoteCount where !used.contains("\(safeBase) \(number)") {
            return "\(safeBase) \(number)"
        }
        return "\(safeBase) \(existingNames.count + 1)"
    }

    public static func migratedLegacyDocument(text: String,
                                              lastEdited: Date?,
                                              defaultName: String,
                                              retention: NoteRetention,
                                              now: Date,
                                              id: UUID = UUID()) -> NotesDocument {
        var document = NotesDocument.initial(defaultName: defaultName, id: id, text: text, modifiedAt: lastEdited)
        document.applyRetention(retention, now: now)
        return document
    }

    public static func requiresCloseConfirmation(_ note: Note) -> Bool {
        !note.text.isEmpty
    }

    public static func shouldClear(lastEdited: Date?, now: Date, retention: NoteRetention) -> Bool {
        guard let limit = retention.maxIdleInterval, let lastEdited else { return false }
        let idle = now.timeIntervalSince(lastEdited)
        return idle > limit
    }

    public static func exportFileName(title: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let safeTitle = sanitizedNoteName(title)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(safeTitle) \(formatter.string(from: date)).txt"
    }
}

// MARK: - Adapter

/// The widget's model: owns the tabbed document, publishes the selected text,
/// and persists every edit debounced — the same contract the floating pad's
/// service offers, without the panel, hotkey, or pin logic.
///
/// Reads and writes the same UserDefaults keys as the upstream service so a
/// note written in one surface is there in the other, and so the retention
/// sweep that runs on load is single-sourced.
@MainActor
@Observable
public final class NotesAdapter {
    // Published for the widget.
    public var text: String = "" {
        didSet {
            guard hasLoaded, !isReplacingText, var document else { return }
            document.updateSelectedText(text, modifiedAt: Date())
            self.document = document
            notes = document.notes
            scheduleSave()
        }
    }

    public private(set) var notes: [Note] = []
    public private(set) var selectedNoteID: UUID?

    public var selectedNoteName: String {
        notes.first(where: { $0.id == selectedNoteID })?.name ?? defaultName
    }

    public var canCreateNote: Bool { notes.count < NotesDocument.maximumNoteCount }
    public var canCloseNote: Bool { notes.count > 1 }

    @ObservationIgnored private var document: NotesDocument?
    @ObservationIgnored private var lastSavedDocument: NotesDocument?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var isReplacingText = false
    /// Set when the stored bytes would not decode. The first write moves them
    /// aside rather than over.
    @ObservationIgnored private var isStoredDocumentUnreadable = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let defaultName: String
    // The feature is called Notes; these keys are not, and must not be. They
    // are upstream's, shared with Vorssaint's floating scratchpad, and renaming
    // either one orphans every note already written.
    @ObservationIgnored private let documentKey = "scratchpadDocument"
    @ObservationIgnored private let retentionKey = "scratchpadRetention"
    @ObservationIgnored private let rescueKey = "scratchpadDocument.unreadable"

    public convenience init() {
        self.init(defaults: .standard, defaultName: "Note")
    }

    public init(defaults: UserDefaults, defaultName: String) {
        self.defaults = defaults
        self.defaultName = defaultName
        loadApplyingRetention()
        observeTermination()
    }

    /// Test seam: in-memory document without touching defaults.
    public init(document: NotesDocument) {
        self.defaults = .standard
        self.defaultName = "Note"
        hasLoaded = true
        apply(document)
        lastSavedDocument = document
        observeTermination()
    }

    deinit {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func observeTermination() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // willTerminate is delivered synchronously while the process exits;
            // hopping to a Task would never run. Flush synchronously on main.
            guard let self else { return }
            MainActor.assumeIsolated {
                self.flushSave()
            }
        }
    }

    // MARK: - Lifecycle

    public func activate() {
        loadApplyingRetention()
    }

    public func deactivate() {
        flushSave()
    }

    /// Notes the running build cannot read are still notes. Before the first
    /// write lands on top of them they are copied to a key nothing else
    /// touches, so a later build — or the user with `defaults read` — can get
    /// them back.
    private func rescueUnreadableDocument() {
        isStoredDocumentUnreadable = false
        guard let stored = defaults.object(forKey: documentKey),
              defaults.object(forKey: rescueKey) == nil
        else { return }
        defaults.set(stored, forKey: rescueKey)
    }

    // MARK: - Document loading

    private func loadApplyingRetention() {
        hasLoaded = true
        if let document, document != lastSavedDocument {
            flushSave()
            return
        }
        let retention = NoteRetention.sanitized(defaults.string(forKey: retentionKey))

        if let stored = defaults.object(forKey: documentKey) {
            let data = stored as? Data
            guard let decoded = data.flatMap({ try? JSONDecoder().decode(NotesDocument.self, from: $0) }) else {
                // Bytes we cannot read are still the user's notes. Show an
                // empty document, but leave the stored value exactly where it
                // is: a build that understands it again can recover it, and
                // writing over it cannot be taken back.
                apply(.initial(defaultName: defaultName))
                lastSavedDocument = nil
                isStoredDocumentUnreadable = true
                return
            }
            var loaded = decoded.sanitized(defaultName: defaultName)
            loaded.applyRetention(retention, now: Date())
            if loaded == decoded {
                lastSavedDocument = loaded
            } else {
                _ = persist(loaded)
            }
            apply(loaded)
            return
        }

        // No stored document: fresh install. Upstream's service would migrate
        // a legacy `Scratchpad.txt` from `PrivateFileStore.containerURL`, but
        // that container is bundle-id-scoped (`com.vorssaint.*` vs
        // `com.controlcenterpro.*`), so CCP's first launch has no file to
        // migrate — intentional not to reach into the old bundle's folder.
        let migrated = NotesDocument.initial(defaultName: defaultName)
        var withRetention = migrated
        withRetention.applyRetention(retention, now: Date())
        _ = persist(withRetention)
        apply(withRetention)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.flushSave() }
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        guard hasLoaded, let document else { return }
        _ = persist(document)
    }

    @discardableResult
    private func persist(_ document: NotesDocument) -> Bool {
        if isStoredDocumentUnreadable { rescueUnreadableDocument() }
        if document == lastSavedDocument { return true }
        guard let data = document.encoded() else { return false }
        defaults.set(data, forKey: documentKey)
        guard defaults.data(forKey: documentKey) == data else { return false }
        lastSavedDocument = document
        return true
    }

    private func apply(_ document: NotesDocument) {
        self.document = document
        notes = document.notes
        selectedNoteID = document.selectedID
        let selectedText = document.notes.first(where: { $0.id == document.selectedID })?.text ?? ""
        isReplacingText = true
        text = selectedText
        isReplacingText = false
    }

    // MARK: - Note verbs

    public func createNote(defaultName: String? = nil) {
        let name = defaultName ?? self.defaultName
        guard let document, let next = document.addingNote(defaultName: name), persist(next) else { return }
        apply(next)
    }

    public func selectNote(_ id: UUID) {
        guard id != selectedNoteID, let document, let next = document.selecting(id), persist(next) else { return }
        apply(next)
    }

    public func renameNote(_ id: UUID, to name: String) {
        guard let document, let next = document.renaming(id, to: name), persist(next) else { return }
        apply(next)
    }

    @discardableResult
    public func closeNote(_ id: UUID) -> Bool {
        guard let document, let next = document.removing(id), persist(next) else { return false }
        apply(next)
        return true
    }

    // MARK: - Actions

    public func copyAll() {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public func clear() {
        guard !text.isEmpty else { return }
        text = ""
        flushSave()
    }

    public var isEmpty: Bool { text.isEmpty }

    /// The bundle Notes syncs towards. Craft ships under its maker's old name,
    /// which is not a thing to work out twice.
    public static let craftBundleIdentifier = "com.lukilabs.lukiapp"

    /// Bring Craft forward. Deliberately activating — this is the one place the
    /// user asked to leave the panel, so stealing focus is the point rather
    /// than the hazard it is everywhere else in the sync work.
    ///
    /// Craft not being installed is a normal state: the button does nothing
    /// rather than presenting an error about an app the user never had.
    public func openCraft() {
        guard let url = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: Self.craftBundleIdentifier)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    public func exportFileName(date: Date = Date()) -> String {
        NotesSupport.exportFileName(title: selectedNoteName, date: date)
    }

    /// Saves `text` to a file chosen via save panel. Kept on the adapter so
    /// the widget view does not need to know the filename format.
    public func exportText(suggestedName: String? = nil) {
        guard !text.isEmpty else { return }
        flushSave()
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.nameFieldStringValue = suggestedName ?? exportFileName()
        let content = text
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            let response = savePanel.runModal()
            if response == .OK, let url = savePanel.url {
                try? content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
