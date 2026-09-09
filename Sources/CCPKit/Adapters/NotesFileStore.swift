// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Posted after the notes folder changes in Settings, so the adapter stops
/// writing to the old folder. The path itself never travels in the
/// notification — the adapter re-resolves it from the settings file.
public extension Notification.Name {
    static let notesFolderDidChange = Notification.Name("ccp.notesFolderDidChange")
}

/// One pad's row in the notes index: where its text lives and what the tabs
/// need without opening the file. The text itself is never here — it is the
/// file's whole content, raw markdown, no frontmatter, so the folder doubles
/// as a vault.
public struct NotesFileIndexEntry: Codable, Equatable, Sendable {
    public var id: UUID
    public var filename: String
    public var name: String
    public var modifiedAt: Date?
    public var closed: Bool

    public init(id: UUID, filename: String, name: String, modifiedAt: Date? = nil, closed: Bool = false) {
        self.id = id
        self.filename = filename
        self.name = name
        self.modifiedAt = modifiedAt
        self.closed = closed
    }
}

/// The notes index: tab order, selection, per-pad filenames, and the dirty
/// set. Small, in UserDefaults under its own key; the files hold the words.
/// Rebuildable from the folder when lost — filenames become names, ids are
/// minted fresh — which heals the tabs at the cost of the sync mappings,
/// since those are keyed by pad id.
public struct NotesFileIndex: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var selectedID: UUID
    public var pads: [NotesFileIndexEntry]
    /// Sorted on write so the encoding is stable.
    public var dirtyPadIDs: [UUID]

    public init(selectedID: UUID, pads: [NotesFileIndexEntry], dirtyPadIDs: [UUID] = []) {
        self.version = Self.currentVersion
        self.selectedID = selectedID
        self.pads = pads
        self.dirtyPadIDs = dirtyPadIDs.sorted(by: { $0.uuidString < $1.uuidString })
    }
}

/// What an index read found. Mirrors the document blob's old contract: a read
/// never destroys evidence, and a rescue is consumed so a good index never
/// eats its own backup.
public enum NotesIndexRead: Equatable, Sendable {
    /// No index key at all: migrate, adopt, or start fresh.
    case absent
    /// A usable index. `rescued` means the live key was unreadable and this
    /// came from the set-aside — re-commit it and set the live bytes aside.
    case index(NotesFileIndex, rescued: Bool)
    /// Bytes exist but nothing decodes: stand in an empty state and keep them.
    case unreadable
}

/// Local truth for Notes: one markdown file per pad plus the index above.
///
/// The index is authoritative for membership — files on disk that it does not
/// list are ignored, never auto-adopted — except when there is no index at
/// all, when the folder's files are adopted as a rebuild.
public struct NotesFileStore {
    /// The folder a fresh install writes into.
    public static let defaultDirectory: URL = .applicationSupport.appendingPathComponent("Notes")

    private let defaults: UserDefaults
    private let directory: URL
    private let indexKey: String

    public init(defaults: UserDefaults, directory: URL, indexKey: String = "scratchpadNotesIndex") {
        self.defaults = defaults
        self.directory = directory
        self.indexKey = indexKey
    }

    // MARK: - Directory

    /// Where pads live: the Settings folder when one is set and usable, the
    /// default otherwise. A path with a plain file sitting on it is not
    /// usable — fall back rather than failing every write.
    public static func resolveDirectory(settings: StoredSettings) -> URL {
        guard let path = settings.notesFolderPath, !path.isEmpty else { return defaultDirectory }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return defaultDirectory
        }
        return url.standardizedFileURL
    }

    // MARK: - Index

    public func loadIndex() -> NotesIndexRead {
        guard let data = defaults.data(forKey: indexKey) else { return .absent }
        if let index = try? JSONDecoder().decode(NotesFileIndex.self, from: data),
           index.version == NotesFileIndex.currentVersion {
            return .index(index, rescued: false)
        }
        if let data = defaults.data(forKey: rescueKey),
           let index = try? JSONDecoder().decode(NotesFileIndex.self, from: data),
           index.version == NotesFileIndex.currentVersion {
            defaults.removeObject(forKey: rescueKey)
            return .index(index, rescued: true)
        }
        return .unreadable
    }

    /// Writes the index. When `settingAsideUnreadable` the live key still
    /// holds bytes we could not read: they move to the rescue key first,
    /// once only, so the first deliberate write preserves rather than
    /// destroys the explanation of why.
    public func saveIndex(_ index: NotesFileIndex, settingAsideUnreadable: Bool = false) {
        if settingAsideUnreadable { setAsideUnreadableIndex() }
        guard let data = try? JSONEncoder().encode(index) else { return }
        defaults.set(data, forKey: indexKey)
    }

    private func setAsideUnreadableIndex() {
        guard defaults.object(forKey: rescueKey) == nil,
              defaults.data(forKey: indexKey) != nil
        else { return }
        defaults.set(defaults.data(forKey: indexKey), forKey: rescueKey)
    }

    private var rescueKey: String { indexKey + ".unreadable" }

    // MARK: - Text files

    /// The pad's text, or nil when the file is missing or unreadable. Both
    /// read as empty upstream — the pad survives either way, and the file
    /// itself is left alone for the next write to set aside.
    public func readText(filename: String) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(filename)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Writes one pad's text atomically. A file whose bytes are not text is
    /// set aside first, once only — overwriting bytes we could not read is
    /// exactly the loss the old blob's rescue path existed for.
    public func writeText(_ text: String, filename: String) throws {
        let url = directory.appendingPathComponent(filename)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setAsideUnreadableFile(at: url)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func setAsideUnreadableFile(at url: URL) {
        let corrupt = url.appendingPathExtension("corrupt")
        guard !FileManager.default.fileExists(atPath: corrupt.path),
              let data = try? Data(contentsOf: url),
              String(data: data, encoding: .utf8) == nil
        else { return }
        try? FileManager.default.moveItem(at: url, to: corrupt)
    }

    /// Removes a pad's file. Best-effort: the index entry is already gone by
    /// the time this runs, so a file left behind is an ignored orphan, never
    /// a resurrected note.
    public func deleteFile(_ filename: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
    }

    /// Renames a pad's file, following a tab rename. A missing source is not
    /// an error — the next write recreates the file under its new name.
    public func moveFile(from oldName: String, to newName: String) throws {
        guard oldName != newName else { return }
        let source = directory.appendingPathComponent(oldName)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: directory.appendingPathComponent(newName))
    }

    /// Moves the listed files to a new folder, for the Settings folder
    /// switch. All-or-nothing: a failure moves back what already moved and
    /// throws, so the caller keeps the old folder rather than splitting the
    /// pads across two.
    public func relocate(filenames: [String], to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var moved: [String] = []
        do {
            for filename in filenames {
                let source = directory.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try FileManager.default.moveItem(at: source, to: destination.appendingPathComponent(filename))
                moved.append(filename)
            }
        } catch {
            for filename in moved {
                try? FileManager.default.moveItem(
                    at: destination.appendingPathComponent(filename),
                    to: directory.appendingPathComponent(filename))
            }
            throw error
        }
    }

    /// Filenames the index lists — the files a folder switch moves. Orphans
    /// and files the user keeps beside the pads stay where they are.
    public func knownFilenames() -> [String] {
        guard case .index(let index, _) = loadIndex() else { return [] }
        return index.pads.map(\.filename)
    }

    /// Every markdown file in the folder, sorted. Only consulted when there
    /// is no index at all — the rebuild adopts what it finds.
    public func markdownFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.filter {
            $0.hasSuffix(".md")
        }.sorted() ?? []
    }

    // MARK: - Filenames

    /// A filename for a pad name: readable, vault-friendly, unique among
    /// `taken`. Duplicate titles get a `-2` suffix, then `-3`, and so on.
    /// Compared case-insensitively: the default filesystem aliases
    /// `Report.md` and `report.md`, so case-variant pads must not share a
    /// stem or the second write eats the first.
    public static func filename(for name: String, excluding taken: Set<String>) -> String {
        var base = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "Note" }
        if base.count > 100 { base = String(base.prefix(100)) }
        let lowered = Set(taken.map { $0.lowercased() })
        var candidate = base + ".md"
        var number = 2
        while lowered.contains(candidate.lowercased()) {
            candidate = "\(base)-\(number).md"
            number += 1
        }
        return candidate
    }

    /// A display name for an adopted file: the filename's stem stands as the
    /// pad's name.
    public static func displayName(for filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        return stem.isEmpty ? "Note" : stem
    }
}
