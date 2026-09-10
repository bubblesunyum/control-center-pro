// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

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

    /// Append a fragment behind a blank line on the named note, leaving
    /// selection alone. A slow-resolving drop lands where it was dropped,
    /// not on whatever tab is selected when the loads finish.
    public mutating func appendText(_ fragment: String, to id: UUID, modifiedAt: Date) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let base = notes[index].text
        let combined: String
        if base.isEmpty {
            combined = fragment
        } else if base.hasSuffix("\n\n") {
            combined = base + fragment
        } else if base.hasSuffix("\n") {
            combined = base + "\n" + fragment
        } else {
            combined = base + "\n\n" + fragment
        }
        guard combined != base else { return }
        notes[index].text = combined
        notes[index].modifiedAt = modifiedAt
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

    public static func requiresDeleteConfirmation(_ note: Note) -> Bool {
        !note.text.isEmpty
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
/// and persists every edit debounced.
///
/// Local truth is a folder of markdown files plus a small index in
/// UserDefaults (selection, tab order, closed tabs, filenames, the dirty
/// set), so the folder doubles as a vault. The old UserDefaults document blob
/// is read once, on migration, and never written again.
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
            if let selectedNoteID { dirtyPadIDs.insert(selectedNoteID) }
            scheduleCraftPush()
        }
    }

    public private(set) var notes: [Note] = []
    public private(set) var selectedNoteID: UUID?
    /// Tabs the X hid. The docs are untouched — text, mapping, sidecar and
    /// sync all stay — so this is CCP UI state under its own key, never the
    /// upstream-shared document. A failed decode reads as nothing hidden.
    public private(set) var closedNoteIDs: Set<UUID> = [] {
        didSet { saveIndex() }
    }

    /// The tabs the strip draws, in document order.
    public var openNotes: [Note] { notes.filter { !closedNoteIDs.contains($0.id) } }
    /// The docs the X hid, in document order — the raw hidden set. The header
    /// menu reads the restorable subset below, never this directly.
    public var closedNotes: [Note] { notes.filter { closedNoteIDs.contains($0.id) } }
    /// The hidden docs worth listing: closed notes with text. An empty note
    /// was never edited, so it never saved to Craft — reopening it restores
    /// nothing. Non-empty is the check (not the Craft mapping) so a just-typed
    /// note lists before its first push lands.
    public var restorableClosedNotes: [Note] { closedNotes.filter { !$0.text.isEmpty } }

    public var selectedNoteName: String {
        notes.first(where: { $0.id == selectedNoteID })?.name ?? defaultName
    }

    public var canCreateNote: Bool { notes.count < NotesDocument.maximumNoteCount }
    /// Whether the strip's X is live for this tab. Almost always true: an
    /// empty tab deletes (freeing its slot) and hiding a non-last tab needs
    /// none — only hiding the last open non-empty tab mints a replacement,
    /// which full house forbids. The strip dims the X there, never hides it,
    /// with the trash as the way out.
    public func canCloseTab(_ id: UUID) -> Bool {
        if notes.first(where: { $0.id == id })?.text.isEmpty == true { return true }
        return openNotes.count != 1 || canCreateNote
    }
    /// Deleting needs a note left over: the document must hold at least one.
    public var canDeleteNote: Bool { notes.count > 1 }

    /// Whether the latest pull has proven Craft reachable. False from
    /// init until the first pull lands, and on every activate until its pull
    /// finishes. Status-only (ccp-t53p): the editor stays open while it
    /// proves, and the toolbar reads syncing/offline meanwhile.
    public private(set) var isSyncVerified = false
    /// The last verification failed: a credential is saved but Craft never
    /// answered. Sticky until the next pull succeeds, so a failing retry
    /// never flickers the status between attempts.
    public private(set) var isSyncCheckFailed = false

    /// A saved connection exists. Without one the pads are local-only notes.
    /// With one the pads still stay editable while the pull proves it —
    /// optimistic editing (ccp-t53p): a landing pull reconciles around
    /// keystrokes (re-reads before adopts, stashes before overwrites,
    /// unmaps instead of deleting unconfirmed text) rather than holding them.
    ///
    /// The file itself is read on events (init, activate, credential
    /// changes), never here: a read can run the one-time Keychain migration
    /// as a side effect, which has no business inside view rendering.
    public var hasCraftCredential: Bool {
        if craftCredentialUnavailable { return false }
        if craftBaseURLOverride != nil { return true }
        return cachedCredentialFilePresence
    }
    @ObservationIgnored private var cachedCredentialFilePresence = false

    private func refreshCredentialPresence() {
        cachedCredentialFilePresence =
            (try? FileCraftCredentialStore().loadConnectionURL()) != nil
    }

    /// Always true: the editor never waits for the pull (ccp-t53p). A pull
    /// that lands on fresh keystrokes stashes or unmaps instead of
    /// overwriting, so holding keystrokes buys nothing. Kept as a property
    /// so call-sites still read intent rather than a literal.
    public var isEditable: Bool { true }

    /// What the toolbar's status corner shows for the selected pad.
    public enum SyncStatus: Equatable, Sendable {
        case localOnly
        case syncing
        case offline
        case unsavedChanges
        case saved
    }

    public var syncStatus: SyncStatus {
        guard hasCraftCredential else { return .localOnly }
        guard isSyncVerified else { return isSyncCheckFailed ? .offline : .syncing }
        if let selectedNoteID {
            if dirtyPadIDs.contains(selectedNoteID) { return .unsavedChanges }
            // Verified and clean but never provisioned — an empty pad, or
            // text the trash sent back to local-only — exists nowhere in
            // Craft, so it must not read as saved there.
            if craftDestination.craftDocumentID(for: selectedNoteID) == nil { return .localOnly }
        }
        return .saved
    }

    @ObservationIgnored private var document: NotesDocument?
    @ObservationIgnored private var lastSavedDocument: NotesDocument?
    /// The index's filename for each pad of the last save. Renames move the
    /// file; this is how the next save knows the old name.
    @ObservationIgnored private var lastSavedFilenames: [UUID: String] = [:]
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var isReplacingText = false
    /// Set when the stored index would not decode. The first write moves it
    /// aside rather than over.
    @ObservationIgnored private var isStoredIndexUnreadable = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var credentialObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var folderObserver: NSObjectProtocol?
    // The Craft connection URL, read once per process. The credential changes
    // only through Settings, which posts craftCredentialDidChange.
    @ObservationIgnored private var cachedCraftBaseURL: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let defaultName: String
    /// Where this adapter's markdown files live. Follows the Settings folder
    /// while the panel is up when `followsSettingsFolder`; tests hand a
    /// temporary folder instead and it never moves under them.
    @ObservationIgnored private var notesDirectory: URL
    @ObservationIgnored private let followsSettingsFolder: Bool
    private var notesStore: NotesFileStore {
        NotesFileStore(defaults: defaults, directory: notesDirectory)
    }
    // The pre-files document blob: upstream's key, shared with Vorssaint's
    // floating scratchpad. Read once, on migration, and cleared after the
    // files verify — never written again, so the two surfaces diverge from
    // the migration forward. Renaming any of these orphans notes that have
    // not migrated yet.
    @ObservationIgnored private let documentKey = "scratchpadDocument"
    @ObservationIgnored private let documentRescueKey = "scratchpadDocument.unreadable"
    // The pre-index closed-tabs key. Migrated into the index the same once.
    @ObservationIgnored private let legacyClosedTabsKey = "scratchpadClosedTabs"
    /// The pad's Craft-side memory behind one seam: sidecars, document ids,
    /// title baselines, stash pins, conflict records, the space id. Same keys
    /// and persisted format the adapter used to own inline. Private so the
    /// seam holds: the engine speaks Craft nouns through it, and nothing else
    /// — no public accessor, no view — may. Hiding the engine's own Craft
    /// vocabulary (CraftClient, CraftPull, BlockSidecar) is the deferred
    /// operation seam (§4.1), not this step.
    @ObservationIgnored private let craftDestination: any CraftSyncStore
    @ObservationIgnored private var pullTask: Task<Void, Never>?
    @ObservationIgnored private var pullRetryTask: Task<Void, Never>?
    /// Seconds between clock-failure retries while the panel stays up.
    private static let pullRetryDelay: TimeInterval = 30
    /// Whether the panel is up. The credential observer re-verifies only
    /// then — a save made while shut must not arm network work nobody
    /// watches; the next activate pulls anyway.
    @ObservationIgnored private var isPanelOpen = false
    // Which tabs the X hid (ccp-xc2j). UI state, kept in the index for the
    // same reason: the files hold text, the index holds where the tabs are.
    // The pre-index key survives above as the migration source only.
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var pushRetryTask: Task<Void, Never>?
    @ObservationIgnored private var isPushInFlight = false
    @ObservationIgnored private var needsPushAfterFlight = false
    /// The pull half of the same gate: a pull deciding on a half-pushed
    /// remote reads our own writes as a move and stashes them, and a push
    /// diffing under an adopting pull gets its sidecar clobbered on
    /// write-back. One round at a time — each side yields to the other and
    /// re-runs after.
    @ObservationIgnored private var isPullInFlight = false
    @ObservationIgnored private var needsPullAfterFlight = false
    @ObservationIgnored private var consecutivePushFailures = 0
    @ObservationIgnored private var pushThrottledUntil: Date?
    /// Pads with edits Craft has not confirmed. Durable in the index
    /// (ccp-q3nd): a quit inside the push debounce used to strand mapped
    /// edits with nothing re-marking them after relaunch. Every mutation
    /// persists the index, so the bit survives anything but its own
    /// clearing — and a pull that skips (remote == sidecar) leaves it
    /// standing for the push `activate` schedules below.
    @ObservationIgnored private var dirtyPadIDs: Set<UUID> = [] {
        didSet { saveIndex() }
    }
    /// Seconds of quiet before an edit pushes. Owned by the type, not a
    /// design token — the 12s focus-dim clock is a different thing (ccp-srw).
    private static let pushDebounce: TimeInterval = 3
    /// Test seams: scripted transport and a fixed URL, so pushes run without
    /// disk or the network.
    @ObservationIgnored internal var craftTransport: (any CraftTransport)?
    @ObservationIgnored internal var craftBaseURLOverride: URL?
    /// Test seam: reads as unconfigured without touching the real store — the
    /// app-support path is a fixed bundle id, so a plain nil override still
    /// finds the developer's credential on their own machine.
    @ObservationIgnored internal var craftCredentialUnavailable = false

    public convenience init() {
        self.init(defaults: .standard, defaultName: "Note", notesDirectory: nil)
    }

    /// - Parameter notesDirectory: where this adapter's markdown files live.
    ///   Nil follows the Settings folder; tests pass a temporary folder so
    ///   the files never touch the real vault.
    public convenience init(defaults: UserDefaults, defaultName: String, notesDirectory: URL?) {
        self.init(defaults: defaults, defaultName: defaultName,
                  notesDirectory: notesDirectory,
                  destination: CraftNoteDestination(defaults: defaults))
    }

    /// Test seam: the sync engine behind a stand-in destination, so the sync
    /// tests prove the seam by substituting a fake for Craft (ccp-2zi.4).
    init(defaults: UserDefaults, defaultName: String, notesDirectory: URL?,
         destination: any CraftSyncStore) {
        self.defaults = defaults
        self.defaultName = defaultName
        self.craftDestination = destination
        if let notesDirectory {
            self.notesDirectory = notesDirectory
            followsSettingsFolder = false
        } else {
            self.notesDirectory = Self.resolveNotesDirectory()
            followsSettingsFolder = true
        }
        refreshCredentialPresence()
        loadDocument()
        observeTermination()
        observeNotesFolderChanges()
    }

    /// Test seam: in-memory document without touching the app's bytes. Edits
    /// still persist, into a throwaway folder under an ephemeral suite — the
    /// point is only that the real vault and index stay clean.
    public init(document: NotesDocument) {
        self.defaults = UserDefaults(suiteName: "ccp.notes.ephemeral.\(UUID().uuidString)") ?? .standard
        self.defaultName = "Note"
        self.craftDestination = CraftNoteDestination(defaults: defaults)
        self.notesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccp.notes.\(UUID().uuidString)")
        followsSettingsFolder = false
        hasLoaded = true
        apply(document)
        lastSavedDocument = nil
        _ = persist(document)
        observeTermination()
    }

    deinit {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = credentialObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = folderObserver {
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
                // Best-effort only: a three-request push will not finish while
                // the process exits, and blocking quit to try is worse. Local
                // bytes are already safe above; Craft lags at most one
                // session, and the next push heals it.
                Task { [weak self] in await self?.flushCraftPush() }
            }
        }
        observeCraftCredentialChanges()
    }

    /// Clear the cached Craft URL when Settings saves or forgets it.
    /// Synchronous delivery (queue nil): an async clear leaves a window where
    /// a push lands on the stale URL and clears the dirty bit for text the
    /// new space never sees. A fresh credential also enables sync for pads
    /// that already hold text: they provision on the next push like any
    /// first edit, so connecting with existing notes converges without
    /// touching anything.
    private func observeCraftCredentialChanges() {
        credentialObserver = NotificationCenter.default.addObserver(
            forName: .craftCredentialDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cachedCraftBaseURL = nil
                self.refreshCredentialPresence()
                // A new credential is unverified until a pull proves it —
                // the pads it maps may already be trashed on the other side.
                // Re-verify now rather than on the next open: the panel may
                // already be up, and the status should reflect the new space.
                self.isSyncVerified = false
                self.isSyncCheckFailed = false
                self.pullTask?.cancel()
                self.pullTask = nil
                self.pullRetryTask?.cancel()
                self.pullRetryTask = nil
                // The deep link's address dies with the credential: opening
                // the old space's doc after forget is a stale launch, and the
                // next pull re-caches after save.
                self.craftDestination.storeCraftSpaceID(nil)
                self.dirtyUnmappedNonEmptyPads()
                // Re-verify now when the panel is up for fresh status.
                // While shut the next activate pulls, so no round starts
                // that nobody watches.
                if self.isPanelOpen {
                    self.schedulePull()
                }
            }
        }
    }

    private static func resolveNotesDirectory() -> URL {
        NotesFileStore.resolveDirectory(settings: JSONFileStore<StoredSettings>(
            filename: "settings.json",
            default: StoredSettings()
        ).load())
    }

    /// Follow the Settings folder switch. The switch already moved the
    /// files; the adapter relearns the folder and reloads from where they
    /// moved to.
    private func observeNotesFolderChanges() {
        guard followsSettingsFolder else { return }
        folderObserver = NotificationCenter.default.addObserver(
            forName: .notesFolderDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.useNotesDirectory(Self.resolveNotesDirectory())
            }
        }
    }

    /// Move this adapter to a new folder: the files are already there (the
    /// Settings switch moves them first). Flushes to the new folder first,
    /// so unsaved keystrokes never land in the old one, then reloads.
    func useNotesDirectory(_ url: URL) {
        notesDirectory = url
        flushSave()
        document = nil
        lastSavedDocument = nil
        lastSavedFilenames = [:]
        loadDocument()
    }
    /// Pads with text but no document are one push away from provisioned.
    /// Empty pads stay local: a document does not exist until the first edit.
    /// Nothing is scheduled without a credential — an unconfigured launch
    /// must not burn a push round on every panel open.
    private func dirtyUnmappedNonEmptyPads() {
        guard craftBaseURL() != nil, let document else { return }
        let fresh = document.notes
            .filter { !$0.text.isEmpty && craftDestination.craftDocumentID(for: $0.id) == nil }
            .map(\.id)
        guard !fresh.isEmpty else { return }
        dirtyPadIDs.formUnion(fresh)
        scheduleCraftPush()
    }

    // MARK: - Lifecycle

    public func activate() {
        refreshCredentialPresence()
        isPanelOpen = true
        pullRetryTask?.cancel()
        pullRetryTask = nil
        if followsSettingsFolder { notesDirectory = Self.resolveNotesDirectory() }
        loadDocument()
        // Pads written before provisioning existed (or before a credential
        // was saved) converge like any first edit — otherwise they sit
        // unmapped and clean until the user happens to type in each one.
        dirtyUnmappedNonEmptyPads()
        // The dirty set is durable now, so a relaunch can own mapped edits
        // the pull will skip (remote == sidecar, local moved). Push them —
        // without this the bit stands but no round ever spends it.
        if !dirtyPadIDs.isEmpty { scheduleCraftPush() }
        // The panel was shut: Craft may have moved under us. Pull now in
        // the background without locking the editor; a failed read changes
        // nothing, and an adopt never lands on unpushed edits without
        // stashing them in Craft first.
        schedulePull()
    }

    public func deactivate() {
        isPanelOpen = false
        pullTask?.cancel()
        pullTask = nil
        pullRetryTask?.cancel()
        pullRetryTask = nil
        // The next activate re-verifies for status: what Craft did
        // while the panel was shut is unknown again. The editor never
        // waits for it.
        isSyncVerified = false
        flushSave()
        // A debounce that only fires while the panel is open loses the last
        // three seconds of every session: push now instead.
        Task { [weak self] in await self?.flushCraftPush() }
    }

    // MARK: - Document loading

    private func loadDocument() {
        hasLoaded = true
        if let document, document != lastSavedDocument {
            flushSave()
            return
        }

        switch notesStore.loadIndex() {
        case .index(let index, let rescued):
            if rescued { isStoredIndexUnreadable = true }
            loadFromIndex(index)
        case .absent:
            migrateAdoptOrFresh()
        case .unreadable:
            // Bytes we cannot read are still the user's state. Stand an
            // empty document in front of them, and treat it as already
            // saved so that closing the panel — which flushes — writes
            // nothing. Only an edit the user makes on purpose is allowed
            // to land on top, and even then the old bytes are copied aside
            // first. Files on disk are left alone either way: the next
            // save uniquifies around them rather than over them.
            let placeholder = NotesDocument.initial(defaultName: defaultName)
            apply(placeholder)
            lastSavedDocument = placeholder
            isStoredIndexUnreadable = true
        }
    }

    /// Rebuild the document from a decoded index: texts come from the files,
    /// everything else from the entries. A missing file is an empty pad, not
    /// a missing one — the tab survives whatever happened on disk.
    private func loadFromIndex(_ index: NotesFileIndex) {
        let notes = index.pads.map { entry -> Note in
            let text = notesStore.readText(filename: entry.filename) ?? ""
            return Note(id: entry.id,
                        name: entry.name,
                        text: text,
                        // An emptied pad carries no date — same rule as the
                        // sanitise pass, applied here so a missing file does
                        // not look like a change that must be saved back.
                        modifiedAt: text.isEmpty ? nil : entry.modifiedAt)
        }
        let decoded = NotesDocument(notes: notes, selectedID: index.selectedID)
        lastSavedFilenames = Dictionary(uniqueKeysWithValues: index.pads.map { ($0.id, $0.filename) })
        closedNoteIDs = Set(index.pads.filter(\.closed).map(\.id))
        dirtyPadIDs = Set(index.dirtyPadIDs)
        let loaded = decoded.sanitized(defaultName: defaultName)
        apply(loaded)
        if loaded == decoded {
            lastSavedDocument = loaded
            // A rescue re-commits what it recovered, so the recovery
            // survives a quit — and sets the live bytes aside first.
            if isStoredIndexUnreadable { saveIndex() }
        } else {
            // Sanitising dropped or repaired a pad: save the clean state.
            lastSavedDocument = nil
            _ = persist(loaded)
        }
    }

    /// No index: a legacy blob migrates once, an index-less folder of files
    /// is adopted as a rebuild, and a true first launch starts blank.
    private func migrateAdoptOrFresh() {
        guard defaults.data(forKey: documentKey) != nil else {
            let files = notesStore.markdownFiles()
            if files.isEmpty {
                let fresh = NotesDocument.initial(defaultName: defaultName).sanitized(defaultName: defaultName)
                lastSavedFilenames = [:]
                closedNoteIDs = []
                dirtyPadIDs = []
                apply(fresh)
                lastSavedDocument = nil
                _ = persist(fresh)
            } else {
                adoptFiles(files)
            }
            return
        }
        migrateLegacyBlob()
    }

    /// The one-time move off the UserDefaults blob: texts into files, order
    /// and selection into the index, closed tabs carried along. The legacy
    /// `pads`/`notes` spellings both decode, like before. The old keys clear
    /// only after the files read back identical — a failed migration keeps
    /// them, so the next launch retries instead of running half-moved.
    /// Craft bookkeeping keys are untouched throughout.
    private func migrateLegacyBlob() {
        let data = defaults.data(forKey: documentKey)
        let liveDecoded = data.flatMap { NotesDocument.decoded($0, defaultName: defaultName) }
        // Peeked, not consumed: the rescue key clears only after the files
        // verify, so a failed migration keeps both copies for the retry.
        let rescuedData = defaults.data(forKey: documentRescueKey)
        let rescued = liveDecoded == nil
            ? rescuedData.flatMap { NotesDocument.decoded($0, defaultName: defaultName) }
            : nil
        let decoded = liveDecoded ?? rescued ?? .initial(defaultName: defaultName)
        closedNoteIDs = Set(Self.decodedClosedNoteIDs(defaults.data(forKey: legacyClosedTabsKey)))
            .intersection(decoded.notes.map(\.id))
        lastSavedFilenames = [:]
        lastSavedDocument = nil
        apply(decoded)
        // Stranded edits predate the durable bit (ccp-q3nd): the old dirty
        // set died with the process, so a mapped pad whose text or title
        // Craft never confirmed would migrate clean and never push until
        // the next keystroke — reading saved while Craft is stale. Unknown
        // reads as unconfirmed, so legacy mappings without a title baseline
        // converge on the next push rather than silently claiming clean.
        dirtyPadIDs = Set(decoded.notes.map(\.id).filter {
            craftDestination.craftDocumentID(for: $0) != nil && hasUnconfirmedEdits($0)
        })
        guard persist(decoded), verifyMigration(of: decoded) else { return }
        // Two consecutive corruptions: the rescue key already holds older
        // evidence and once-only keeps it, so the blob stays as the newer
        // exhibit rather than being cleared. The index exists, so nothing
        // ever migrates from it again — it is evidence, not state.
        if liveDecoded != nil || rescued != nil || rescuedData == nil {
            defaults.removeObject(forKey: documentKey)
        }
        if rescued != nil {
            // The live bytes were unreadable: they move to the rescue key
            // now that its previous occupant is verified into the files —
            // evidence, not trash.
            defaults.set(data, forKey: documentRescueKey)
        } else if liveDecoded == nil, rescuedData == nil {
            // Nothing decoded: keep the bytes once-only, like before.
            defaults.set(data, forKey: documentRescueKey)
        } else if liveDecoded != nil {
            // Verified live supersedes whatever an old incident set aside.
            defaults.removeObject(forKey: documentRescueKey)
        }
        defaults.removeObject(forKey: legacyClosedTabsKey)
    }

    /// The files just written read back identical to the migrated document:
    /// same pads, names, texts and selection, same closed set.
    private func verifyMigration(of document: NotesDocument) -> Bool {
        guard case .index(let index, _) = notesStore.loadIndex() else { return false }
        guard index.selectedID == document.selectedID,
              index.pads.count == document.notes.count
        else { return false }
        for note in document.notes {
            guard let entry = index.pads.first(where: { $0.id == note.id }),
                  entry.name == note.name,
                  // Both sides shed: the read sheds hard-break debris and the
                  // legacy blob is exactly where that debris lives, so an
                  // un-shed comparison fails the migration for the only pads
                  // that ever had any (ccp-ra2l).
                  notesStore.readText(filename: entry.filename) == HardBreak.normalized(note.text)
            else { return false }
        }
        return Set(index.pads.filter(\.closed).map(\.id)) == closedNoteIDs
    }

    /// Adopt an index-less folder as a rebuild: every markdown file becomes
    /// a pad under a fresh id, filenames kept. The files already hold the
    /// text, so only the index is new — and the pads provision to Craft like
    /// any first edit.
    private func adoptFiles(_ files: [String]) {
        var usedNames = Set<String>()
        var entries: [NotesFileIndexEntry] = []
        for filename in files.prefix(NotesDocument.maximumNoteCount) {
            let stem = NotesFileStore.displayName(for: filename)
            var name = NotesSupport.sanitizedNoteName(stem)
            if name.isEmpty || usedNames.contains(name) {
                name = NotesSupport.nextNoteName(
                    defaultName: name.isEmpty ? defaultName : name,
                    existingNames: Array(usedNames))
            }
            usedNames.insert(name)
            let id = UUID()
            entries.append(NotesFileIndexEntry(
                id: id, filename: filename, name: name,
                modifiedAt: nil, closed: false))
        }
        let notes = entries.map { entry in
            Note(id: entry.id, name: entry.name,
                 text: notesStore.readText(filename: entry.filename) ?? "")
        }
        guard let first = notes.first else { return }
        let adopted = NotesDocument(notes: notes, selectedID: first.id)
        lastSavedFilenames = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.filename) })
        closedNoteIDs = []
        dirtyPadIDs = []
        apply(adopted)
        lastSavedDocument = adopted
        saveIndex()
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
        // Equality first: an unchanged document must not trigger the rescue,
        // because the rescue clears the flag that guards the bytes.
        if document == lastSavedDocument { return true }
        let previous = lastSavedDocument
        let known = lastSavedFilenames
        // A pad keeps its file while its name stands; renames and new pads
        // take a fresh filename that collides with nothing on disk — not
        // even files the index has forgotten, which are evidence, never
        // scratch space.
        var taken = Set(known.values).union(notesStore.markdownFiles())
        var assigned: [UUID: String] = [:]
        for note in document.notes {
            if let old = previous?.notes.first(where: { $0.id == note.id }),
               old.name == note.name, let file = known[note.id] {
                assigned[note.id] = file
            }
        }
        var moves: [(from: String, to: String)] = []
        for note in document.notes where assigned[note.id] == nil {
            let file = NotesFileStore.filename(for: note.name, excluding: taken)
            if let old = known[note.id], old != file { moves.append((old, file)) }
            assigned[note.id] = file
            taken.insert(file)
        }
        // Moves land before the mapping and index commit, and the rollback
        // above only runs on thrown errors — a kill -9 between the two
        // strands text in a correctly-named orphan. That is the loud
        // direction, chosen on purpose: the pad reads empty while its text
        // sits visible in the vault, rather than the index claiming a file
        // whose content predates the rename. Crash-atomic moves want a
        // journal; that is filed work, not this commit.
        var moved: [(from: String, to: String)] = []
        for move in moves {
            do {
                try notesStore.moveFile(from: move.from, to: move.to)
                moved.append(move)
            } catch {
                // Back out the renames that already landed: the mapping and
                // the index below still name the old files, so a half-moved
                // folder would strand text in orphans on the next load.
                for done in moved.reversed() {
                    try? notesStore.moveFile(from: done.to, to: done.from)
                }
                return false
            }
        }
        for note in document.notes {
            guard let file = assigned[note.id] else { return false }
            let oldText = previous?.notes.first(where: { $0.id == note.id })?.text
            if oldText == note.text, known[note.id] != nil { continue }
            do { try notesStore.writeText(note.text, filename: file) }
            catch { return false }
        }
        // Pads the document no longer names fall out of the mapping here;
        // their files are deleted explicitly by deleteNote, so a dropped pad
        // anywhere else leaves an ignored orphan rather than a lost note.
        lastSavedFilenames = assigned
        lastSavedDocument = document
        saveIndex(for: document)
        return true
    }

    /// Writes the index for the committed document plus the live closed and
    /// dirty sets. Reads the committed document rather than the live one:
    /// every verb persists before it applies, so between the two the live
    /// document is still the previous save — and a didSet firing there
    /// (deleteNote's drops, say) must not resurrect what persist just
    /// removed. Short-circuits before anything committed, which is also
    /// what keeps the loading didSets quiet. Consumes the unreadable flag
    /// on its first real write, setting the old bytes aside first.
    private func saveIndex() {
        guard hasLoaded, let document = lastSavedDocument else { return }
        saveIndex(for: document)
    }

    /// The index for the document just persisted. Takes it as a parameter
    /// rather than reading the committed one because persist advances the
    /// mapping first — the fallback below would otherwise provisional-name
    /// pads the mapping already knows.
    private func saveIndex(for document: NotesDocument) {
        // Provisional names avoid nothing on disk either: a save that lands
        // between this index write and the persist that corrects it must
        // still not point a pad at a stranger's file. Case falls out of
        // filename(for:excluding:), which compares insensitively.
        var taken = Set(lastSavedFilenames.values).union(notesStore.markdownFiles())
        let entries = document.notes.map { note -> NotesFileIndexEntry in
            let file: String
            if let known = lastSavedFilenames[note.id] {
                file = known
            } else {
                file = NotesFileStore.filename(for: note.name, excluding: taken)
                taken.insert(file)
            }
            return NotesFileIndexEntry(id: note.id, filename: file, name: note.name,
                                       modifiedAt: note.modifiedAt, closed: closedNoteIDs.contains(note.id))
        }
        notesStore.saveIndex(NotesFileIndex(selectedID: document.selectedID, pads: entries,
                                            dirtyPadIDs: Array(dirtyPadIDs)),
                             settingAsideUnreadable: isStoredIndexUnreadable)
        isStoredIndexUnreadable = false
    }

    private func apply(_ document: NotesDocument) {
        self.document = document
        notes = document.notes
        pruneClosedNoteIDs()
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
        // Selecting shows: a hidden tab chosen from the menu rejoins the
        // strip. Unhiding first fails toward a harmless ghost tab — hiding
        // first would strand the new selection hidden when the persist lands
        // and the unhide never does.
        unhide(id)
        guard id != selectedNoteID, let document, let next = document.selecting(id), persist(next) else { return }
        apply(next)
    }

    public func renameNote(_ id: UUID, to name: String) {
        guard let document, let next = document.renaming(id, to: name), persist(next) else { return }
        apply(next)
        // An effectively-unchanged name (whitespace-only difference) commits
        // nothing: stamping the LWW clock here would let a no-op outrank a
        // genuinely newer remote rename.
        guard next.notes.first(where: { $0.id == id })?.name != document.notes.first(where: { $0.id == id })?.name
        else { return }
        // A rename is a syncable change like an edit: stamp it for
        // last-writer-wins and visit Craft on the next push, even when the
        // text is clean. Unmapped pads keep the bit harmlessly — provisioning
        // names the document from the pad, so the title converges at creation.
        craftDestination.storeTitleRenameDate(Date(), for: id)
        dirtyPadIDs.insert(id)
        scheduleCraftPush()
    }

    /// Hide a tab. The doc is untouched — text, sync mapping and sidecar all
    /// stay, and the push and pull keep visiting it — so nothing is lost and
    /// nothing asks first. An empty tab deletes instead: hiding it would
    /// strand it outside the restorable menu while leaking a slot, and
    /// deletion is identical from the user's side (nothing to reopen),
    /// confirmation-free while empty. Hiding the last open tab mints a fresh
    /// blank note first, so the strip never empties. Everything lives on in
    /// Craft either way.
    @discardableResult
    public func closeTab(_ id: UUID) -> Bool {
        if notes.first(where: { $0.id == id })?.text.isEmpty == true {
            if notes.count == 1 {
                // Sole blank tab: deletion refuses the last doc, so reset —
                // fresh blank in place of the dismissed one. Count 1 mints.
                createNote()
            }
            return deleteNote(id)
        }
        var opens = openNotes
        if opens.count == 1, opens.first?.id == id {
            // Last open tab: mint the replacement first — selection is
            // already on the new tab, and the path below hides the old one.
            guard canCreateNote else { return false }
            createNote()
            opens = openNotes
        }
        guard let index = opens.firstIndex(where: { $0.id == id }) else { return false }
        if selectedNoteID == id {
            // Selection first, hide second: a torn pair then leaves a visible
            // ghost tab, never a selected tab with nowhere to be seen. An
            // unpersisted move hides nothing at all.
            let neighbour = index + 1 < opens.count ? opens[index + 1] : opens[index - 1]
            guard let document, let next = document.selecting(neighbour.id), persist(next) else { return false }
            apply(next)
        }
        closedNoteIDs.insert(id)
        return true
    }

    /// Bring a hidden tab back and show it. Heals outright: whatever hid the
    /// selected tab — a torn write, a foreign edit of the shared document —
    /// the menu row unhides first and asks questions later.
    @discardableResult
    public func reopenTab(_ id: UUID) -> Bool {
        guard let document, document.notes.contains(where: { $0.id == id }) else { return false }
        unhide(id)
        selectNote(id)
        return selectedNoteID == id
    }

    /// Delete a doc: the note, its text, its file, and every per-pad sync
    /// trace. Mints a fresh note when none would stay open. Nothing hidden
    /// ever resurrects: deleting the last open tab opens a fresh blank note
    /// instead, and a fallback that landed on a hidden tab yields to the
    /// nearest open neighbour.
    @discardableResult
    public func deleteNote(_ id: UUID) -> Bool {
        guard let document,
              let deletedIndex = document.notes.firstIndex(where: { $0.id == id }),
              var next = document.removing(id)
        else { return false }
        if next.notes.allSatisfy({ closedNoteIDs.contains($0.id) }) {
            guard let fresh = next.addingNote(defaultName: defaultName) else { return false }
            next = fresh
        } else if closedNoteIDs.contains(next.selectedID),
                  let neighbour = nearestOpenNote(toDeletedIndex: deletedIndex, in: next.notes) {
            next = next.selecting(neighbour.id) ?? next
        }
        // The filename before the persist drops it from the mapping — and
        // the file goes after, so a crash between the two leaves an ignored
        // orphan rather than an index entry with no text.
        let filename = lastSavedFilenames[id]
        guard persist(next) else { return false }
        if let filename { notesStore.deleteFile(filename) }
        dropSyncState(for: id)
        dropHistory(for: id)
        unhide(id)
        apply(next)
        return true
    }

    /// Every per-pad sync trace, in one place: deleteNote and unmapPad share
    /// it, so the next key never updates one and misses the other.
    private func dropSyncState(for id: UUID) {
        craftDestination.dropSyncState(for: id)
        dirtyPadIDs.remove(id)
        conflictsVersion += 1
    }

    /// History dies with the pad: snapshots are the way back into text that
    /// no longer exists. Unmapping keeps them — the pad survives local-only,
    /// still edited, and the undo-clear still depends on the way back.
    private func dropHistory(for id: UUID) {
        craftDestination.dropSnapshots(for: id)
        padsPendingUndoClear.remove(id)
        snapshotsVersion += 1
    }

    /// Settle one pad whose Craft doc is trashed (ccp-5fom). A converged pad
    /// deletes — remote deletes win — but a pad holding text Craft never
    /// confirmed keeps its text and goes local-only instead: deleting that
    /// would destroy the only copy in either place. A sole pad mints its
    /// replacement first, since deleteNote refuses the last doc.
    private func settleTrashedPad(_ padID: UUID) {
        guard craftDestination.craftDocumentID(for: padID) != nil,
              document?.notes.contains(where: { $0.id == padID }) == true
        else { return }
        guard !hasUnconfirmedEdits(padID) else {
            unmapPad(padID)
            return
        }
        if document?.notes.count == 1 {
            createNote()
        }
        deleteNote(padID)
    }

    /// Whether the pad holds changes Craft never confirmed: the durable
    /// dirty bit, a block diff against the last confirmed sidecar (the plan
    /// is what the pull decides by), or a title the baseline never recorded. Unknown
    /// baselines read as unconfirmed: a legacy mapping's first trash-hit
    /// keeps its text rather than deleting on a maybe.
    private func hasUnconfirmedEdits(_ padID: UUID) -> Bool {
        if dirtyPadIDs.contains(padID) { return true }
        guard let document,
              let pad = document.notes.first(where: { $0.id == padID })
        else { return false }
        let slices = CraftBlockSplitter.slices(in: pad.text)
        if !craftDestination.sidecar(for: padID).pushPlan(for: slices).isEmpty { return true }
        guard let baseline = craftDestination.syncedTitle(for: padID) else {
            // No baseline — a legacy mapping or never converged: keep the
            // text on a maybe rather than deleting.
            return true
        }
        return pad.name != baseline
    }

    /// Whether a push round would spend any request on this pad — the trash
    /// sweep's gate, so no-op rounds cost nothing (and no scripts). Mirrors
    /// pushOnePad's own checks without provisioning: an unmapped pad with
    /// syncable slices would create, a mapped pad writes when its title or
    /// its blocks differ.
    private func padNeedsPush(_ padID: UUID) -> Bool {
        guard let document,
              let pad = document.notes.first(where: { $0.id == padID })
        else { return false }
        let slices = CraftBlockSplitter.slices(in: pad.text)
        guard craftDestination.craftDocumentID(for: padID) != nil else { return !slices.isEmpty }
        if pad.name != craftDestination.syncedTitle(for: padID) { return true }
        return !craftDestination.sidecar(for: padID).pushPlan(for: slices).isEmpty
    }

    /// Drop every per-pad sync trace and keep the note: text, tab and
    /// selection stand, local-only. The next edit provisions a fresh Craft
    /// doc like any first edit.
    private func unmapPad(_ padID: UUID) {
        dropSyncState(for: padID)
    }

    /// Nearest open note to a deletion. `toDeletedIndex` is pre-delete, but
    /// the same integer in the post-delete array points at the old successor —
    /// which is why the forward side checks first. Nil only when nothing is
    /// open, which the caller mints away first.
    private func nearestOpenNote(toDeletedIndex index: Int, in notes: [Note]) -> Note? {
        for distance in 0..<notes.count {
            for candidate in [index + distance, index - distance] {
                guard notes.indices.contains(candidate),
                      !closedNoteIDs.contains(notes[candidate].id)
                else { continue }
                return notes[candidate]
            }
        }
        return nil
    }

    /// Closed ids for docs that no longer exist prune on every apply: without
    /// this a replaced document leaks them forever. The selected tab unhides
    /// with them — selection is always visible, so a stuck hidden-selected
    /// tab heals on the next load instead of lingering.
    private func pruneClosedNoteIDs() {
        guard let document else { return }
        let live = Set(document.notes.map(\.id))
        if !closedNoteIDs.isSubset(of: live) {
            closedNoteIDs = closedNoteIDs.intersection(live)
        }
        unhide(document.selectedID)
    }

    /// Unhide without the spurious index write a bare remove would spend on
    /// every select: the set only writes when an id actually leaves it.
    private func unhide(_ id: UUID) {
        if closedNoteIDs.contains(id) {
            closedNoteIDs.remove(id)
        }
    }

    /// The legacy closed-tabs set, for the migration only. A failed decode
    /// reads as nothing hidden.
    private static func decodedClosedNoteIDs(_ data: Data?) -> Set<UUID> {
        guard let data,
              let ids = try? JSONDecoder().decode(Set<UUID>.self, from: data)
        else { return [] }
        return ids
    }

    // MARK: - Craft push

    /// Create the pad's Craft document. The doc is born EMPTY in `unsorted`
    /// (title = pad name at creation, never renamed after) and the content
    /// follows as the empty-doc first sync in the same round. The mapping
    /// itself lands in pushOnePad, after a liveness re-check — a throw, or a
    /// pad closed mid-create, stores nothing, so a retry never orphans a
    /// document the sidecar does not know and deleted text is never pushed.
    private func provisionCraftDocument(name: String, client: CraftClient) async throws -> String {
        try await client.createDocument(title: name).id
    }

    private func craftBaseURL() -> URL? {
        // Cached: the file read is cheap but pointless to repeat per push.
        // Cleared when the credential is saved or forgotten (see observeCraftCredentialChanges).
        if craftCredentialUnavailable { return nil }
        if let cached = cachedCraftBaseURL { return cached }
        let loaded = craftBaseURLOverride ?? (try? FileCraftCredentialStore().loadConnectionURL())
        cachedCraftBaseURL = loaded
        return loaded
    }

    private func scheduleCraftPush() {
        // The retry task is deliberately NOT cancelled here: an edit during
        // backoff must not eat the only scheduled healing. Both tasks funnel
        // into runCraftPush, where the second is a cheap no-op.
        pushTask?.cancel()
        pushTask = nil
        guard !isPushInFlight else {
            needsPushAfterFlight = true
            return
        }
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pushDebounce))
            guard !Task.isCancelled else { return }
            await self?.runCraftPush()
        }
    }

    /// Start a fresh pull round, replacing any in flight. The replaced round
    /// stands down cooperatively; the gate keeps the overlap honest — a new
    /// round arriving inside the old one yields and re-runs after it.
    private func schedulePull() {
        pullTask?.cancel()
        pullTask = Task { [weak self] in await self?.pullAll() }
    }

    /// Re-run rounds that yielded to a finished one: a deferred push
    /// debounces as usual, a deferred pull runs while the panel is up —
    /// shut, the next activate pulls anyway and no round starts unwatched.
    private func drainAfterFlight() {
        if needsPushAfterFlight {
            needsPushAfterFlight = false
            scheduleCraftPush()
        }
        if needsPullAfterFlight {
            needsPullAfterFlight = false
            if isPanelOpen { schedulePull() }
        }
    }

    /// Push now: the deactivate path and tests. Explicit, so it bypasses the
    /// throttle window — a panel close right after a failure still tries.
    /// Coalesces with an in-flight push rather than running beside it.
    public func flushCraftPush() async {
        pushTask?.cancel()
        pushTask = nil
        pushRetryTask?.cancel()
        pushRetryTask = nil
        await pushNow()
    }

    private func runCraftPush() async {
        pushTask = nil
        // A throttled drop must not lose the retry: the edit that armed this
        // run cancelled nothing, but an older topology might have, so top up
        // a missing retry for the remaining window.
        if isPushThrottled {
            if pushRetryTask == nil, let until = pushThrottledUntil {
                schedulePushRetry(after: max(until.timeIntervalSinceNow, 0))
            }
            return
        }
        await pushNow()
    }

    /// Observable for tests: a failed push stays failed until the window
    /// passes, and debounced runs hold until then.
    var isPushThrottled: Bool {
        if let throttledUntil = pushThrottledUntil { Date() < throttledUntil } else { false }
    }

    private func pushNow() async {
        pushTask = nil
        // One round at a time: re-entry coalesces, and a pull deciding
        // mid-push reads a half-written remote as a move — so a debounced
        // push landing inside a pull waits for the next round instead.
        guard !isPushInFlight, !isPullInFlight else { needsPushAfterFlight = true; return }
        guard let baseURL = craftBaseURL() else { return }
        isPushInFlight = true
        defer {
            isPushInFlight = false
            drainAfterFlight()
        }
        let client = CraftClient(baseURL: baseURL, transport: craftTransport)
        var failure: Error?
        // Mid-session deletes (ccp-5fom): the trash may have taken a doc
        // while the panel sat open, and a trashed doc still answers writes
        // with 200 — pushing would strand local text inside Craft's trash.
        // Settle those pads before writing; settled pads leave the dirty
        // set, so the snapshot below never resurrects them. Gated on mapped
        // pads this round would actually write to — unmapped pads have no
        // doc to be trashed, and no-op rounds still cost nothing at all.
        // Unknown trash blocks the round rather than green-lighting it: a
        // blind write is exactly what strands the text.
        let mappedWriters = dirtyPadIDs.filter {
            craftDestination.craftDocumentID(for: $0) != nil && padNeedsPush($0)
        }
        let attempted: [UUID]
        if mappedWriters.isEmpty {
            attempted = Array(dirtyPadIDs)
        } else if let trashed = try? await client.trashedDocumentIDs(),
                  craftBaseURL() == baseURL {
            for padID in Array(dirtyPadIDs) where craftBaseURL() == baseURL {
                if let docID = craftDestination.craftDocumentID(for: padID), trashed.contains(docID) {
                    settleTrashedPad(padID)
                }
            }
            // Snapshot: pads clear or fail below, which mutates the set.
            attempted = Array(dirtyPadIDs)
        } else if craftBaseURL() == baseURL {
            // The trash listing failed with the credential steady: writing
            // blind risks stranding text in a trashed doc, so the round
            // backs off like any failed round with the dirty bits standing.
            failure = CraftClientError.unreachable(statusCode: nil)
            attempted = []
        } else {
            // The credential switched mid-sweep: nothing settled can be
            // trusted, and the end-of-round accounting starts the new space
            // with fresh chances rather than the old round's failure.
            attempted = []
        }
        for padID in attempted {
            // The credential may have switched after the sweep: remaining
            // pads stop rather than writing into the old space, and the
            // end-of-round re-dirty below retries them against the new one.
            guard craftBaseURL() == baseURL else { break }
            do {
                // False is not failure (throw is): the pad was edited
                // mid-flight, so it stays dirty for the follow-up round.
                let pushedClean = try await pushOnePad(padID, client: client)
                if pushedClean {
                    dirtyPadIDs.remove(padID)
                }
            } catch {
                failure = failure ?? error
                // Backpressure stops the round, not just the pad: unvisited
                // pads would each spend their own creates into the throttled
                // window before the backoff below lands.
                if let clientError = error as? CraftClientError,
                   case .rateLimited = clientError {
                    break
                }
            }
        }
        if craftBaseURL() != baseURL {
            // The credential changed mid-round and this round wrote to the
            // old space. Nothing it cleared can be trusted — every attempted
            // pad goes again against the new one, where the diff either
            // converges quiet (same space re-saved) or retries loud.
            dirtyPadIDs.formUnion(attempted)
        }
        if let failure {
            consecutivePushFailures += 1
            let delay = retryDelay(for: failure)
            // Gate debounced runs for the same window the retry waits out:
            // typing must not hammer a server that just said slow down. The
            // dirty set keeps the intent; the next edit past the window
            // retries, and so does the retry task if nothing cancels it.
            pushThrottledUntil = Date().addingTimeInterval(delay ?? Self.pushRetryDelays[2])
            schedulePushRetry(after: delay)
        } else {
            consecutivePushFailures = 0
            pushThrottledUntil = nil
        }
    }

    /// Push one dirty pad. Progress is stored even on the way out: every leg
    /// records what the server confirmed, so a retry diffs from the last
    /// confirmed state — replaying a confirmed POST is what duplicates
    /// blocks. Skips (no credential, pad gone, empty plan) clear the dirty bit
    /// silently; edits re-dirty if the pad comes back. A throw keeps the pad
    /// dirty and every later round retries it.
    ///
    /// Returns false when the pad was edited mid-flight: the stored sidecar
    /// describes the pushed text, not the current text, so the pad stays
    /// dirty and the already-scheduled follow-up pushes the new text.
    private func pushOnePad(_ padID: UUID, client: CraftClient) async throws -> Bool {
        guard let document,
              let pad = document.notes.first(where: { $0.id == padID })
        else { return true }
        let padText = pad.text
        let slices = CraftBlockSplitter.slices(in: padText)
        var docID = craftDestination.craftDocumentID(for: padID)
        if docID == nil {
            // Lazy provisioning (ccp-0gek): no local pad without a Craft doc.
            // The doc is created EMPTY on first push and the content follows
            // as the empty-doc first sync below, so the head problem never
            // arises. Nothing syncable, no document — the splitter skipping
            // blank text is what decides, not the string being empty, so a
            // whitespace-only pad provisions nothing. (No credential never
            // reaches here: pushNow returns before visiting any pad.)
            guard !slices.isEmpty else { return true }
            let newID = try await provisionCraftDocument(name: pad.name, client: client)
            // The create awaited: a pad closed meanwhile must not resurrect.
            // Re-read the live document, not the pre-await snapshot — its
            // mapping, sidecar, and drops already ran in deleteNote. Store
            // nothing and push nowhere: the orphaned empty doc is trash
            // noise, but deleted text reaching Craft would be data loss.
            guard self.document?.notes.contains(where: { $0.id == padID }) == true else { return true }
            craftDestination.setCraftDocumentID(newID, for: padID)
            // A new sync relationship gets fresh chances.
            consecutivePushFailures = 0
            pushThrottledUntil = nil
            // Born named: the creation title IS the pad's name, so the title
            // baseline starts converged — no rename PUT follows.
            craftDestination.storeSyncedTitle(pad.name, for: padID)
            docID = newID
        }
        guard let docID else { return true }
        // Unknown baseline reads as dirty: the push converges it. (A legacy
        // mapping the pull saw first already recorded Craft's title there, so
        // this only fires for pads the push reaches before any pull.)
        let titleDirty = pad.name != craftDestination.syncedTitle(for: padID)
        let sidecar = craftDestination.sidecar(for: padID)
        let plan = sidecar.pushPlan(for: slices)
        guard !plan.isEmpty || titleDirty else { return true }

        var pendingError: Error?
        var titleEcho: CraftBlock?
        var putEcho: [CraftBlock] = []
        var echoByInsert: [Int: [CraftBlock]] = [:]
        var deletesConfirmed = plan.deletes.isEmpty
        if titleDirty {
            // Its own leg, not the head of the content pipeline: a failed
            // title must not starve the text behind it. Backpressure is the
            // exception — another write into a throttled window only spends
            // budget, so a rate-limited title skips the content legs.
            do {
                titleEcho = try await client.updateDocumentTitle(id: docID, title: pad.name)
            } catch let titleError as CraftClientError {
                pendingError = titleError
                if case .rateLimited = titleError {
                    throw titleError
                }
            }
        }
        do {
            if !plan.updates.isEmpty {
                putEcho = try await client.updateBlocks(plan.updates)
            }
            // One batch per anchor group, in plan order; abort the rest on
            // the first throw. Echoes stay keyed by plan-insert index, so a
            // split can never shift a later insert's attribution. Anchorless
            // groups carry the sidecar's head into postBlocks, which posts
            // at the end and moves before it (ccp-gfe5).
            for group in postGroups(for: plan) {
                let headSibling = group.first?.insert.afterID == nil
                    ? sidecar.entries.first?.id : nil
                let echo = try await client.postBlocks(group.map(\.insert),
                                                       documentID: docID,
                                                       headSiblingID: headSibling)
                for (i, member) in group.enumerated() where i < echo.count {
                    echoByInsert[member.index, default: []].append(echo[i])
                }
                if echo.count > group.count, let last = group.last {
                    echoByInsert[last.index, default: []]
                        .append(contentsOf: echo.dropFirst(group.count))
                }
            }
            if !plan.deletes.isEmpty {
                try await client.deleteBlocks(plan.deletes)
                deletesConfirmed = true
            }
        } catch {
            // Backpressure wins the error: the retry delay answers the
            // server's pacing, not the first failure's.
            if pendingError == nil { pendingError = error }
            if case .rateLimited = error as? CraftClientError { pendingError = error }
        }
        // The pad may be gone: the push awaited, and deleteNote's drops
        // already ran. Storing now would resurrect sync state for a dead UUID
        // that pulls never visit and UUIDs never reuse — leaking forever.
        guard self.document?.notes.contains(where: { $0.id == padID }) == true else { return true }
        // The echo's canonical markdown is the baseline, never what was
        // sent — by the same fixed-point rule as the block sidecar, compared
        // post-sanitise like the pull does. Recorded even on the way out: a
        // later content failure must not un-confirm a title Craft holds.
        if let titleEcho {
            let confirmed = NotesSupport.sanitizedNoteName(titleEcho.markdown)
            if !confirmed.isEmpty { craftDestination.storeSyncedTitle(confirmed, for: padID) }
        }
        storePushOutcome(padID: padID, sidecar: sidecar, text: padText, slices: slices,
                         putEcho: putEcho, postEchoByInsert: echoByInsert,
                         deletesConfirmed: deletesConfirmed)
        if let pendingError { throw pendingError }
        let current = self.document?.notes.first(where: { $0.id == padID })
        return current?.text == padText && current?.name == pad.name
    }

    /// Observable for tests.
    func isPushDirty(_ id: UUID) -> Bool { dirtyPadIDs.contains(id) }

    /// Observable for tests: a failed push leaves a retry scheduled.
    var hasScheduledRetry: Bool { pushRetryTask != nil }

    private func storePushOutcome(padID: UUID, sidecar: BlockSidecar, text: String,
                                  slices: [CraftBlockSlice],
                                  putEcho: [CraftBlock], postEchoByInsert: [Int: [CraftBlock]],
                                  deletesConfirmed: Bool) {
        let newSidecar = sidecar.applyingPush(text: text, slices: slices,
                                           putEcho: putEcho, postEchoByInsert: postEchoByInsert,
                                           deletesConfirmed: deletesConfirmed)
        craftDestination.storeSidecar(newSidecar, for: padID)
    }

    /// One POST batch per anchor group, in plan order. Anchorless inserts
    /// (head of the pad) post at the end and move before the sidecar's head
    /// block: no single POST inserts above the first block — "start"+pageId
    /// and "before"+siblingId both merge into it (observed live 2026-09-05,
    /// ccp-gfe5). The empty-document first sync keeps "start"+pageId, where
    /// there is no head block to address.
    ///
    /// Known limit, accepted for .5: hand-mapping a pad onto a contentful
    /// Craft doc (outside the provisioning flow, ccp-0gek) addresses a head
    /// block the sidecar never saw. Provisioning must only ever map
    /// empty-or-pull-seeded docs; the pull seed heals the order the one time
    /// this fires.
    private func postGroups(for plan: BlockPushPlan) -> [[(index: Int, insert: BlockInsert)]] {
        guard !plan.inserts.isEmpty else { return [] }
        let indexed = plan.inserts.enumerated().map { (index: $0.offset, insert: $0.element) }
        return groupedInserts(indexed)
    }

    private static let pushRetryDelays: [TimeInterval] = [30, 120, 300]

    private func retryDelay(for error: Error) -> TimeInterval? {
        switch error as? CraftClientError {
        case .rateLimited(let retryAfter):
            // Floored: a Retry-After of 0 must not hot-loop against a server
            // that just said slow down.
            return min(max(retryAfter ?? Self.pushRetryDelays[0], 5), Self.pushRetryDelays[2])
        case .unreachable, nil:
            let step = min(consecutivePushFailures - 1, Self.pushRetryDelays.count - 1)
            guard consecutivePushFailures <= Self.pushRetryDelays.count else { return nil }
            return Self.pushRetryDelays[max(step, 0)]
        }
    }

    private func schedulePushRetry(after delay: TimeInterval?) {
        guard let delay else { return }
        pushRetryTask?.cancel()
        pushRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.runCraftPush()
        }
    }

    /// Order-preserving group-by for batching inserts per anchor.
    private func groupedInserts(_ inserts: [(index: Int, insert: BlockInsert)])
        -> [[(index: Int, insert: BlockInsert)]] {
        var order: [String?] = []
        var groups: [String?: [(index: Int, insert: BlockInsert)]] = [:]
        for member in inserts {
            if groups[member.insert.afterID] == nil { order.append(member.insert.afterID) }
            groups[member.insert.afterID, default: []].append(member)
        }
        return order.compactMap { groups[$0] }
    }

    // MARK: - Craft pull

    // MARK: - Craft conflict records

    /// Bumped on every record/dismiss/drop. The records live behind the
    /// destination, which observation cannot see — views read it through
    /// `conflicts(for:)` so they refresh when the set changes (a background
    /// pull recording, a dismiss emptying the list).
    private(set) var conflictsVersion = 0

    /// Conflicts stashed for a pad, newest first. Empty when none ever
    /// stashed — pins from before records existed list nothing.
    public func conflicts(for id: UUID) -> [ConflictRecord] {
        _ = conflictsVersion
        return craftDestination.conflicts(for: id)
    }

    /// Forgets one conflict record. The Craft-side copy and its sidecar pins
    /// stay: forgetting must never re-echo the copy into the pad.
    public func dismissConflict(_ recordID: UUID, for id: UUID) {
        craftDestination.dismissConflict(recordID, for: id)
        conflictsVersion += 1
    }

    /// Test seam: the pull spends this on a landed stash. The destination
    /// keeps the records; the bump publishes for the toolbar.
    func recordConflict(slices: [String], date: Date?, for id: UUID) {
        craftDestination.recordConflict(slices: slices, date: date, for: id)
        conflictsVersion += 1
    }

    // MARK: - Pad history (ccp-o3k)

    /// Bumped on every snapshot record. Views read the ring through
    /// `snapshots(for:)`, which the destination hides from observation.
    private(set) var snapshotsVersion = 0

    /// Pads whose wholesale replacement the surface has not yet answered by
    /// clearing the editor's undo stack. A set, not a slot: one pull adopts
    /// every mapped pad, and SwiftUI may coalesce the bumps into a single
    /// delivery carrying only the last. Entries for background pads linger
    /// harmlessly — the engine invalidates their stacks on switch-back, and
    /// switching to one acknowledges it.
    public private(set) var padsPendingUndoClear: Set<UUID> = []

    /// The surface spent the replacement: the stack is dropped, the
    /// snapshots keep the way back. Switching to a pending pad acknowledges
    /// without clearing — the engine's switch-back invalidation owns that
    /// stack, and a stale flag must never clear fresh keystrokes later.
    public func acknowledgeUndoClear(for id: UUID) {
        padsPendingUndoClear.remove(id)
    }

    /// Pre-replacement copies for a pad, newest first. Empty when no pull,
    /// merge, or restore ever replaced its text.
    public func snapshots(for id: UUID) -> [PadSnapshot] {
        _ = snapshotsVersion
        return craftDestination.snapshots(for: id)
    }

    /// Spend this before replacing: the destination keeps the ring, the bump
    /// publishes for the menu. adoptRemote and restoreSnapshot call it on
    /// the production path; tests seed the ring through it.
    func recordSnapshot(markdown: String, reason: SnapshotReason, date: Date?, for id: UUID) {
        craftDestination.recordSnapshot(markdown: markdown, reason: reason, date: date, for: id)
        snapshotsVersion += 1
    }

    /// Restore a snapshot's text over the pad. The current text snapshots
    /// first (as preRestore), so restoring is reversible from the same menu
    /// — and it pushes like any other edit: the restore is visible, and the
    /// way back is one menu item away rather than silent.
    public func restoreSnapshot(_ snapshotID: UUID, for id: UUID) {
        guard let snapshot = craftDestination.snapshots(for: id).first(where: { $0.id == snapshotID }),
              var document, let index = document.notes.firstIndex(where: { $0.id == id })
        else { return }
        let current = document.notes[index].text
        guard current != snapshot.markdown else { return }
        if !current.isEmpty,
           !craftDestination.snapshots(for: id).contains(where: { $0.markdown == current }) {
            // A current text the ring already holds needs no backup:
            // restoring it later lands on identical bytes, so recording
            // would only spend the cap — and a full ring would evict genuine
            // history for the duplicate.
            recordSnapshot(markdown: current, reason: .preRestore, date: Date(), for: id)
        }
        document.notes[index].text = snapshot.markdown
        document.notes[index].modifiedAt = Date()
        self.document = document
        notes = document.notes
        if id == selectedNoteID {
            // Through didSet: persists, marks dirty, schedules the push.
            text = snapshot.markdown
        } else {
            _ = persist(document)
            dirtyPadIDs.insert(id)
            scheduleCraftPush()
        }
        padsPendingUndoClear.insert(id)
    }

    /// Pull every mapped pad: one clock read, one trash listing, then one
    /// block fetch each. A failed clock verifies nothing — the pads stay
    /// exactly as they are, editable, until a retry proves Craft reachable —
    /// and one pad's failure never skips the rest. Observable for tests; the
    /// activate path fires it as a task.
    func pullAll(fromRetry: Bool = false) async {
        // A retry round must stay cancellable while it runs, so entry only
        // clears the handle it did not arrive on: a fresh round cancels a
        // pending retry, while the retry itself keeps its handle so a later
        // deactivate can still stand it down. (fromRetry earns its keep —
        // the two entries have different cancellation semantics.)
        if fromRetry {
            guard pullRetryTask != nil else { return }
        } else {
            pullRetryTask?.cancel()
            pullRetryTask = nil
        }
        guard let baseURL = craftBaseURL() else { return }
        // The mirror half: a fetch landing inside a push reads the
        // half-written remote as a move and stashes our own writes. Yield;
        // the push re-runs this round on its way out. A second pull
        // arriving inside the first coalesces the same way — deciding twice
        // on one pre-store sidecar double-posts the stash.
        guard !isPushInFlight, !isPullInFlight else { needsPullAfterFlight = true; return }
        isPullInFlight = true
        defer {
            isPullInFlight = false
            drainAfterFlight()
        }
        isSyncVerified = false
        isSyncCheckFailed = false
        let client = CraftClient(baseURL: baseURL, transport: craftTransport)
        let space = try? await client.checkConnection()
        // Stale or cancelled rounds touch nothing — not even the deep-link
        // cache a cancelled clock would otherwise clear below.
        guard craftBaseURL() == baseURL, !Task.isCancelled else { return }
        // The deep link's address refreshes with the clock read the pull
        // already pays for — no extra request when the button is pressed.
        craftDestination.storeCraftSpaceID(space?.spaceID)
        let serverTime = space?.serverTime
        guard space != nil else {
            isSyncCheckFailed = true
            // One transient 500 at open must not strand the session:
            // retry while the panel is up. A later activate or credential
            // change cancels this and starts its own round.
            schedulePullRetry()
            return
        }
        // The credential changed mid-flight: the observer already started a
        // fresh pull for the new space, so this round stands down rather
        // than attesting — or deleting for — a URL it never used.
        guard craftBaseURL() == baseURL, !Task.isCancelled else { return }
        let mappedPadIDs = craftDestination.mappedPadIDs
        // Remote deletes win (ccp-5fom): a doc Craft trashed settles its pad
        // here — deleted when converged, kept local-only when it holds text
        // Craft never confirmed — through the same drop set as the toolbar
        // trash, so the strip and the overflow menu follow with no view
        // changes. Membership only: a failed trash read skips the pass
        // rather than deleting, and a fetch 404 on a doc the trash does not
        // name is a scope problem, never a delete.
        if let trashed = try? await client.trashedDocumentIDs() {
            for padID in mappedPadIDs {
                guard craftBaseURL() == baseURL, !Task.isCancelled else { return }
                if let docID = craftDestination.craftDocumentID(for: padID), trashed.contains(docID) {
                    settleTrashedPad(padID)
                }
            }
        }
        for padID in craftDestination.mappedPadIDs {
            guard craftBaseURL() == baseURL, !Task.isCancelled else { return }
            // A throw is one pad's "store unreachable", never the loop's.
            try? await pullOnePad(padID, client: client, serverTime: serverTime)
        }
        guard craftBaseURL() == baseURL, !Task.isCancelled else { return }
        isSyncVerified = true
    }

    /// One more chance after a failed clock read. Fixed and short: success
    /// verifies, another failure reschedules, and anything that starts its
    /// own round (activate, credential change, deactivate) cancels this.
    private func schedulePullRetry() {
        pullRetryTask?.cancel()
        pullRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pullRetryDelay))
            guard !Task.isCancelled else { return }
            await self?.pullAll(fromRetry: true)
        }
    }

    private func pullOnePad(_ padID: UUID, client: CraftClient, serverTime: Date?) async throws {
        guard let docID = craftDestination.craftDocumentID(for: padID) else { return }
        let fetched = try await client.fetchDocument(documentID: docID)
        guard !Task.isCancelled else { return }
        // Re-read after the fetch: keystrokes interleave with the await, and
        // deciding on pre-fetch text strands them between the stash and the
        // adopt — in neither the pad nor the Craft copy.
        guard let document,
              let pad = document.notes.first(where: { $0.id == padID })
        else { return }
        let remoteIDs = Set(fetched.blocks.map(\.id))
        switch CraftPull.decide(local: pad.text, sidecar: craftDestination.sidecar(for: padID),
                                remote: fetched.blocks, stashIDs: craftDestination.stashIDs(for: padID)) {
        case .converged:
            craftDestination.storeSyncedAt(serverTime, for: padID)
            dirtyPadIDs.remove(padID)
        case .adopt(let text, let newSidecar):
            adoptRemote(padID: padID, text: text, sidecar: newSidecar,
                        snapshotReason: .pull, snapshotDate: serverTime)
            craftDestination.storeStashIDs(craftDestination.stashIDs(for: padID).intersection(remoteIDs), for: padID)
            craftDestination.storeSyncedAt(serverTime, for: padID)
            dirtyPadIDs.remove(padID)
        case .conflict(let heading, let stash, let text, let seeded):
            // The stash appends at the document's end: every insert shares
            // the last remote id as its anchor, so the batch lands in array
            // order behind it (the same batching the push relies on). Into
            // an empty document the anchorless batch takes start+pageId,
            // where there is no head block to merge into.
            let inserts = [Self.conflictHeading(heading, at: serverTime)] + stash
            let echo = try await client.postBlocks(
                inserts.map { BlockInsert(afterID: fetched.blocks.last?.id, markdown: $0) },
                documentID: docID)
            // Recorded before the re-read below: the copy exists in Craft
            // whatever the user typed meanwhile, and the next pull must
            // already know to keep it out of the pad.
            let stashed = craftDestination.stashIDs(for: padID).intersection(remoteIDs).union(echo.map(\.id))
            craftDestination.storeStashIDs(stashed, for: padID)
            // The popover lists what was preserved and when; recorded only
            // for the copy that actually landed.
            recordConflict(slices: stash, date: serverTime, for: padID)
            // The stash pins unwritable: it lives in Craft, never in the
            // pad, so the next push must route around it rather than
            // delete what it cannot see.
            var sidecar = seeded
            for item in echo {
                sidecar.entries.append(BlockSidecarEntry(
                    id: item.id, fingerprint: BlockSidecar.fingerprint(item.markdown),
                    isWritable: false))
            }
            // The sidecar advances even when the text cannot: the POST just
            // changed Craft, and a sidecar predating the stash reads those
            // blocks as a second remote move and posts the stash again.
            craftDestination.storeSidecar(sidecar, for: padID)
            // Re-read after the POST: adopting now would overwrite keystrokes
            // newer than the stash and clear their dirty bit. Leave the text —
            // the stash just posted is their safety copy, and the next pull
            // stashes the fresh text the same way. (`document` above is the
            // pre-POST snapshot; the live state is re-read here.)
            guard self.document?.notes.first(where: { $0.id == padID })?.text == pad.text
            else { return }
            adoptRemote(padID: padID, text: text, sidecar: sidecar,
                        snapshotReason: .conflict, snapshotDate: serverTime)
            craftDestination.storeSyncedAt(serverTime, for: padID)
            dirtyPadIDs.remove(padID)
        case .skip:
            break
        }
        // Title runs after the content decision landed (a throwing stash
        // leaves the title for the next pull), and even when the content
        // skipped: the two move independently. A content adopt that cleared
        // the dirty bit is safe — a still-dirty title re-adds it below.
        reconcileTitle(padID: padID, remoteTitle: fetched.title,
                       remoteModified: fetched.modifiedAt, serverTime: serverTime)
    }

    /// Reconcile one pad's name against the fetched page-root title.
    private func reconcileTitle(padID: UUID, remoteTitle: String?,
                                remoteModified: Date?, serverTime: Date?) {
        guard let document,
              let index = document.notes.firstIndex(where: { $0.id == padID }),
              craftDestination.craftDocumentID(for: padID) != nil
        else { return }
        let localName = document.notes[index].name
        // Compared post-sanitise, like every rename: a >40-char Craft title
        // then converges instead of fighting the tab strip forever. An empty
        // remote title reconciles nothing — pad names are never empty, so
        // there is no adoption that keeps both sides meaningful.
        guard let remoteName = remoteTitle.map(NotesSupport.sanitizedNoteName),
              !remoteName.isEmpty
        else {
            // A title-less fetch (envelope shapes) decides nothing — but it
            // must not strand a known-local rename the content decision just
            // cleared: re-assert the bit when the baseline says local moved.
            // Baseline-less mappings wait for a page-shaped pull instead.
            if let baseline = craftDestination.syncedTitle(for: padID), localName != baseline {
                dirtyPadIDs.insert(padID)
                scheduleCraftPush()
            }
            return
        }
        guard let baseline = craftDestination.syncedTitle(for: padID) else {
            // No baseline: the mapping predates title sync. Craft's title is
            // the record; a differing pad name pushes local on the next round
            // — pad wins, because the tab strip is the daily surface and the
            // divergence almost always came from a local rename (the ccp-o2dh
            // complaint), not from a deliberate Craft-side rename.
            craftDestination.storeSyncedTitle(remoteName, for: padID)
            if localName != remoteName {
                // The "almost" needs a trace: a deliberate Craft-side rename
                // would otherwise be overwritten with nothing to show for it.
                // Content stashes a copy in Craft; a title has nowhere to put
                // one — the push is about to destroy it there — so the record
                // is the preservation, and the conflicts popover is the way back.
                recordConflict(slices: ["Craft title “\(remoteName)” was replaced by “\(localName)”"],
                               date: serverTime, for: padID)
                dirtyPadIDs.insert(padID)
                scheduleCraftPush()
            }
            return
        }
        switch (localName != baseline, remoteName != baseline) {
        case (false, false):
            break
        case (true, false):
            dirtyPadIDs.insert(padID)
            scheduleCraftPush()
        case (false, true):
            adoptTitle(padID: padID, title: remoteName, date: remoteModified ?? serverTime)
        case (true, true):
            // Last-writer-wins; ties and unknown clocks break local, so a
            // rename never lands under typing hands on a maybe.
            if let remoteModified,
               let renamedAt = craftDestination.titleRenameDate(for: padID),
               remoteModified > renamedAt {
                adoptTitle(padID: padID, title: remoteName, date: remoteModified)
            } else {
                dirtyPadIDs.insert(padID)
                scheduleCraftPush()
            }
        }
    }

    /// Take a Craft-side rename silently: no dirty bit, no push — what just
    /// arrived must not echo back. The rename date becomes the adoption's
    /// clock, so a later local rename still has something to beat.
    private func adoptTitle(padID: UUID, title: String, date: Date?) {
        guard let document,
              let next = document.renaming(padID, to: title),
              persist(next)
        else { return }
        apply(next)
        craftDestination.storeSyncedTitle(next.notes.first(where: { $0.id == padID })?.name ?? title, for: padID)
        craftDestination.storeTitleRenameDate(date ?? Date(), for: padID)
    }

    /// Replace a pad's text and sidecar from a pull. Silent: the replacing
    /// flag keeps the widget from re-dirtying and re-pushing what just
    /// arrived, and the persist lands now rather than on the save debounce.
    private func adoptRemote(padID: UUID, text: String, sidecar: BlockSidecar,
                             snapshotReason: SnapshotReason, snapshotDate: Date?) {
        guard var document,
              let index = document.notes.firstIndex(where: { $0.id == padID })
        else { return }
        let current = document.notes[index].text
        let replaced = current != text
        if replaced, !current.isEmpty {
            // The pre-pull text survives in history, so the editor's undo
            // stack — stranded at stale ranges by the replacement — may drop.
            recordSnapshot(markdown: current, reason: snapshotReason, date: snapshotDate, for: padID)
        }
        document.notes[index].text = text
        document.notes[index].modifiedAt = Date()
        self.document = document
        notes = document.notes
        if padID == selectedNoteID {
            isReplacingText = true
            self.text = text
            isReplacingText = false
        }
        if replaced {
            padsPendingUndoClear.insert(padID)
        }
        craftDestination.storeSidecar(sidecar, for: padID)
        _ = persist(document)
    }

    /// The stash heading, dated by the server clock when the pull brought
    /// one. The date is a label, never a comparison — an unknown clock dates
    /// nothing rather than stamping Mac time Craft never saw.
    static func conflictHeading(_ base: String, at serverTime: Date?) -> String {
        guard let serverTime else { return base }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return "\(base) — \(formatter.string(from: serverTime))"
    }

    // MARK: - Actions

    public func copyAll() {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Append a dropped fragment to the selected note, separated from
    /// existing text by a blank line. The clipboard-to-notes drag lands
    /// here, and so does any Finder or browser drop on the note well.
    public func appendDroppedText(_ dropped: String) {
        appendDroppedText(dropped, to: selectedNoteID)
    }

    /// Append to the note selected at drop time, not at resolve time: a
    /// slow-resolving drop must land where it was dropped, without yanking
    /// a tab the user has since moved away from. When that note is gone —
    /// the trash pass deletes converged pads under a resolving drop — fall
    /// back to the selected note rather than eating the fragment.
    func appendDroppedText(_ dropped: String, to noteID: UUID?) {
        let fragment = dropped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fragment.isEmpty, hasLoaded, !isReplacingText,
              var document else { return }
        let landingID: UUID
        if let noteID, document.notes.contains(where: { $0.id == noteID }) {
            landingID = noteID
        } else if let selected = selectedNoteID,
                  document.notes.contains(where: { $0.id == selected }) {
            landingID = selected
        } else {
            return
        }
        let before = document
        document.appendText(fragment, to: landingID, modifiedAt: Date())
        guard document != before else { return }
        self.document = document
        notes = document.notes
        if landingID == selectedNoteID {
            isReplacingText = true
            text = document.notes.first(where: { $0.id == landingID })?.text ?? text
            isReplacingText = false
        }
        scheduleSave()
        dirtyPadIDs.insert(landingID)
        scheduleCraftPush()
    }

    /// Resolve dropped providers into note text: files contribute paths,
    /// links their address, text itself. Images have no text form and are
    /// declined, so an image drag springs back instead of appending nothing.
    /// True when at least one provider is viable, with the appends landing
    /// async as each load finishes, in provider order.
    @discardableResult
    public func acceptDrop(providers: [NSItemProvider]) -> Bool {
        let viable = providers.filter(Self.canResolveDrop)
        guard !viable.isEmpty, let target = selectedNoteID else { return false }
        Task { @MainActor [weak self] in
            for provider in viable {
                guard let fragment = await Self.droppedText(from: provider) else { continue }
                self?.appendDroppedText(fragment, to: target)
            }
        }
        return true
    }

    private static func canResolveDrop(_ provider: NSItemProvider) -> Bool {
        // Rich types count as viable on their own: an unparseable RTF-only
        // provider then accepts and lands nothing, but every real source
        // pairs rich bytes with plain text, so the fallthrough covers it.
        // Refusing rich-only here would spring-back drops the converter
        // could have kept.
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.html.identifier)
            || provider.canLoadObject(ofClass: NSString.self)
    }

    private static func droppedText(from provider: NSItemProvider) async -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadDropURL(from: provider), url.isFileURL,
           !isDragShim(url, provider: provider) {
            return url.path
        }
        // A file URL also satisfies `.url`, so these stay declined here: a
        // file that fell out of the branch above is a shim, and its content
        // waits in the text branch — a `file://` address string is never
        // what the note should hold.
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadDropURL(from: provider), !url.isFileURL {
            return url.absoluteString
        }
        // Styled bytes convert ahead of plain text, so a formatted copy
        // keeps its shape as Markdown; anything else falls through to the
        // string the drag already carried.
        if provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.html.identifier) {
            let rtf = await loadDropData(forTypeIdentifier: UTType.rtf.identifier, from: provider)
            let html = await loadDropData(forTypeIdentifier: UTType.html.identifier, from: provider)
            if let converted = RichTextMarkdown.markdown(rtf: rtf, html: html) {
                return converted
            }
        }
        // Explicit only: every file-URL provider implicitly vends its
        // `file://` address as a string, which must never land in a note.
        if provider.vendsExplicitText,
           let string = await loadDropString(from: provider) {
            return string as String
        }
        return nil
    }

    /// Shelf text/link rows dual-register a temp-file URL alongside their
    /// real text, so the file branch would file a rotting /tmp path instead
    /// of the content. A temp-dir file that explicitly vends text is that
    /// shim: real /tmp drops from Finder vend no text, and our own
    /// single-file drags vend the path itself as text, so preferring text
    /// changes nothing there.
    private static func isDragShim(_ url: URL, provider: NSItemProvider) -> Bool {
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL
        return url.standardizedFileURL.path.hasPrefix(temp.path + "/")
            && provider.vendsExplicitText
    }

    private static func loadDropURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { object, _ in
                continuation.resume(returning: object as? URL)
            }
        }
    }

    private static func loadDropString(from provider: NSItemProvider) async -> NSString? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: object as? NSString)
            }
        }
    }

    private static func loadDropData(forTypeIdentifier identifier: String,
                                     from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
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

    /// The deep link onto one document, in the shape `GET /connection`
    /// reports under `urlTemplates.app`. Pure for tests; the app opens it.
    public static func craftDocumentURL(spaceID: String, blockID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "craftdocs"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "spaceId", value: spaceID),
            URLQueryItem(name: "blockId", value: blockID),
        ]
        return components.url
    }

    /// Open the selected pad's own Craft doc. A pad with no doc yet, or a
    /// space never verified, falls back to bringing Craft forward.
    public func openCraftDocument() {
        if let selectedNoteID,
           let docID = craftDestination.craftDocumentID(for: selectedNoteID),
           let spaceID = craftDestination.craftSpaceID,
           let url = Self.craftDocumentURL(spaceID: spaceID, blockID: docID) {
            NSWorkspace.shared.open(url)
        } else {
            openCraft()
        }
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

private extension NSItemProvider {
    /// Whether text was explicitly registered, rather than merely coercible:
    /// every file-URL provider implicitly loads its `file://` address as a
    /// string, which must never land in a note.
    var vendsExplicitText: Bool {
        registeredTypeIdentifiers.contains {
            UTType($0)?.conforms(to: .text) == true
        }
    }
}
