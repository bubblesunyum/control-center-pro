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

    public static func requiresDeleteConfirmation(_ note: Note) -> Bool {
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
        didSet { persistClosedNoteIDs() }
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

    /// Whether this activate's pull has proven Craft reachable. False from
    /// init until the first pull lands, and on every activate until its pull
    /// finishes — keystrokes typed meanwhile could interleave with the fetch
    /// that decides adopts, conflicts, and remote deletes (ccp-5fom).
    public private(set) var isSyncVerified = false
    /// The last verification failed: a credential is saved but Craft never
    /// answered. Sticky until the next pull succeeds, so a failing retry
    /// never flickers the gate open between attempts.
    public private(set) var isSyncCheckFailed = false

    /// A saved connection exists. Without one the pads are local-only notes
    /// and stay editable; a credential that exists but never verified is not
    /// this — those pads may have a Craft counterpart, so they wait.
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

    /// Typing is allowed for local-only pads and for verified pads. An
    /// unverified pad may be deleted out from under the caret by the landing
    /// pull, so the editor holds until the pull is in.
    public var isEditable: Bool { !hasCraftCredential || isSyncVerified }

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
            if craftDocumentID(for: selectedNoteID) == nil { return .localOnly }
        }
        return .saved
    }

    @ObservationIgnored private var document: NotesDocument?
    @ObservationIgnored private var lastSavedDocument: NotesDocument?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var isReplacingText = false
    /// Set when the stored bytes would not decode. The first write moves them
    /// aside rather than over.
    @ObservationIgnored private var isStoredDocumentUnreadable = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var credentialObserver: NSObjectProtocol?
    // The Craft connection URL, read once per process. The credential changes
    // only through Settings, which posts craftCredentialDidChange.
    @ObservationIgnored private var cachedCraftBaseURL: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let defaultName: String
    // The feature is called Notes; these keys are not, and must not be. They
    // are upstream's, shared with Vorssaint's floating scratchpad, and renaming
    // either one orphans every note already written.
    @ObservationIgnored private let documentKey = "scratchpadDocument"
    @ObservationIgnored private let retentionKey = "scratchpadRetention"
    @ObservationIgnored private let rescueKey = "scratchpadDocument.unreadable"
    // The Craft block-id sidecar (ccp-xgl): pad id to the (block id, hash)
    // pairing the push diffs against. Ours, not upstream's, so it lives
    // under its own key — sync bookkeeping, never note text.
    @ObservationIgnored private let sidecarKey = "scratchpadCraftSidecars"
    @ObservationIgnored private let sidecarsRescueKey = "scratchpadCraftSidecars.unreadable"
    @ObservationIgnored private var isStoredSidecarsUnreadable = false
    // Pull bookkeeping (ccp-2zi.6): the last server moment each pad agreed
    // with Craft. Advisory — moved detection is an exact signature compare,
    // never the clock — and feed for the sync-status widget. A failed decode
    // reads as never-synced, never as a reason to touch the pad.
    @ObservationIgnored private let syncedAtKey = "scratchpadCraftSyncedAt"
    @ObservationIgnored private var pullTask: Task<Void, Never>?
    @ObservationIgnored private var pullRetryTask: Task<Void, Never>?
    /// Seconds between clock-failure retries while the panel stays up.
    private static let pullRetryDelay: TimeInterval = 30
    /// Whether the panel is up. The credential observer re-verifies only
    /// then — a save made while shut must not arm network work nobody
    /// watches; the next activate pulls anyway.
    @ObservationIgnored private var isPanelOpen = false
    // Conflict copies a pad posted (ccp-2zi.6): Craft block ids that pin the
    // sidecar and stay out of the pad. Apart from the sidecar's policy flags
    // on purpose — a policy-unwritable block the user fixes in Craft must
    // rejoin the pad, while a stash copy must never come back. No legacy
    // state to migrate: the pull never ran before this bead, so no sidecar
    // in the wild carries conflict pins yet.
    @ObservationIgnored private let stashKey = "scratchpadCraftStash"
    // Conflict records for the popover (ccp-omt1): what each stash preserved
    // and when, per pad, newest first. The pins stay the sync's business.
    @ObservationIgnored private let conflictsKey = "scratchpadCraftConflicts"
    // Push bookkeeping (ccp-2zi.5). The pad-to-document mapping is config,
    // like retention and selection — never note text.
    @ObservationIgnored private let craftDocumentsKey = "scratchpadCraftDocuments"
    // Title sync (ccp-o2dh): the last Craft-confirmed title per pad, plus
    // when the pad was last renamed locally. The pair is what makes a rename
    // a syncable change — differing from the baseline is dirty in either
    // direction, and the rename date settles both-sides-moved against the
    // page root's mtime.
    @ObservationIgnored private let syncedTitleKey = "scratchpadCraftTitles"
    @ObservationIgnored private let titleRenamedAtKey = "scratchpadCraftTitleRenamedAt"
    // Which tabs the X hid (ccp-xc2j). UI state under its own key for the
    // same reason: the document bytes are upstream's, this set is ours.
    @ObservationIgnored private let closedTabsKey = "scratchpadClosedTabs"
    // The space id GET /connection reports (ccp-xc2j). What the per-document
    // deep link is addressed with. Refreshed on every pull's clock read.
    @ObservationIgnored private let craftSpaceIDKey = "scratchpadCraftSpaceID"
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var pushRetryTask: Task<Void, Never>?
    @ObservationIgnored private var isPushInFlight = false
    @ObservationIgnored private var needsPushAfterFlight = false
    @ObservationIgnored private var consecutivePushFailures = 0
    @ObservationIgnored private var pushThrottledUntil: Date?
    @ObservationIgnored private var dirtyPadIDs: Set<UUID> = []
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
        self.init(defaults: .standard, defaultName: "Note")
    }

    public init(defaults: UserDefaults, defaultName: String) {
        self.defaults = defaults
        self.defaultName = defaultName
        closedNoteIDs = Self.decodedClosedNoteIDs(defaults.data(forKey: closedTabsKey))
        refreshCredentialPresence()
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
        if let observer = credentialObserver {
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
                // already be up, and the editor holds until the pull lands.
                self.isSyncVerified = false
                self.isSyncCheckFailed = false
                self.pullTask?.cancel()
                self.pullTask = nil
                self.pullRetryTask?.cancel()
                self.pullRetryTask = nil
                // The deep link's address dies with the credential: opening
                // the old space's doc after forget is a stale launch, and the
                // next pull re-caches after save.
                self.defaults.removeObject(forKey: self.craftSpaceIDKey)
                self.dirtyUnmappedNonEmptyPads()
                // Re-verify now when the panel is up — the editor holds until
                // the pull lands. While shut the next activate pulls, so no
                // round starts that nobody watches.
                if self.isPanelOpen {
                    self.pullTask = Task { [weak self] in await self?.pullAll() }
                }
            }
        }
    }

    /// Pads with text but no document are one push away from provisioned.
    /// Empty pads stay local: a document does not exist until the first edit.
    /// Nothing is scheduled without a credential — an unconfigured launch
    /// must not burn a push round on every panel open.
    private func dirtyUnmappedNonEmptyPads() {
        guard craftBaseURL() != nil, let document else { return }
        let fresh = document.notes
            .filter { !$0.text.isEmpty && craftDocumentID(for: $0.id) == nil }
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
        loadApplyingRetention()
        // Pads written before provisioning existed (or before a credential
        // was saved) converge like any first edit — otherwise they sit
        // unmapped and clean until the user happens to type in each one.
        dirtyUnmappedNonEmptyPads()
        // The panel was shut: Craft may have moved under us. Pull now; a
        // failed read changes nothing, and an adopt never lands on unpushed
        // edits without stashing them in Craft first.
        pullTask?.cancel()
        pullTask = Task { [weak self] in await self?.pullAll() }
    }

    public func deactivate() {
        isPanelOpen = false
        pullTask?.cancel()
        pullTask = nil
        pullRetryTask?.cancel()
        pullRetryTask = nil
        // The next activate re-verifies before unlocking: what Craft did
        // while the panel was shut is unknown again.
        isSyncVerified = false
        flushSave()
        // A debounce that only fires while the panel is open loses the last
        // three seconds of every session: push now instead.
        Task { [weak self] in await self?.flushCraftPush() }
    }

    /// Notes the running build cannot read are still notes. Before the first
    /// write lands on top of them they are copied to a key nothing else
    /// touches, so a later build — or the user with `defaults read` — can get
    /// them back.
    /// A document rescued from an earlier unreadable state, if this build can
    /// read it now. Without this the backup is only reachable by hand, which
    /// is not a recovery path — it is a consolation.
    private func rescuedDocument() -> NotesDocument? {
        guard let data = defaults.data(forKey: rescueKey),
              let document = try? JSONDecoder().decode(NotesDocument.self, from: data)
        else { return nil }
        defaults.removeObject(forKey: rescueKey)
        return document
    }

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
            guard let decoded = data.flatMap({ try? JSONDecoder().decode(NotesDocument.self, from: $0) })
                ?? rescuedDocument()
            else {
                // Bytes we cannot read are still the user's notes. Stand an
                // empty document in front of them, and treat it as already
                // saved so that closing the panel — which flushes — writes
                // nothing. Only an edit the user makes on purpose is allowed
                // to land on top, and even then the old bytes are copied aside
                // first.
                let placeholder = NotesDocument.initial(defaultName: defaultName)
                apply(placeholder)
                lastSavedDocument = placeholder
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
        // Equality first: an unchanged document must not trigger the rescue,
        // because the rescue clears the flag that guards the bytes.
        if document == lastSavedDocument { return true }
        if isStoredDocumentUnreadable { rescueUnreadableDocument() }
        guard let data = document.encoded() else { return false }
        defaults.set(data, forKey: documentKey)
        guard defaults.data(forKey: documentKey) == data else { return false }
        lastSavedDocument = document
        return true
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
        storeTitleRenameDate(Date(), for: id)
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

    /// Delete a doc: the note, its text, and every per-pad sync trace. Mints a
    /// fresh note when none would stay open. Nothing hidden ever resurrects:
    /// deleting the last open tab opens a fresh blank note instead, and a
    /// fallback that landed on a hidden tab yields to the nearest open
    /// neighbour.
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
        guard persist(next) else { return false }
        dropSyncState(for: id)
        unhide(id)
        apply(next)
        return true
    }

    /// Every per-pad sync trace, in one place: deleteNote and unmapPad share
    /// it, so the next key never updates one and misses the other.
    private func dropSyncState(for id: UUID) {
        dropSidecar(for: id)
        dropCraftDocumentID(for: id)
        dropSyncedTitle(for: id)
        dropTitleRenameDate(for: id)
        dropConflicts(for: id)
        dropStashIDs(for: id)
        dropSyncedAt(for: id)
        dirtyPadIDs.remove(id)
    }

    /// Settle one pad whose Craft doc is trashed (ccp-5fom). A converged pad
    /// deletes — remote deletes win — but a pad holding text Craft never
    /// confirmed keeps its text and goes local-only instead: deleting that
    /// would destroy the only copy in either place. A sole pad mints its
    /// replacement first, since deleteNote refuses the last doc.
    private func settleTrashedPad(_ padID: UUID) {
        guard craftDocumentID(for: padID) != nil,
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

    /// Whether the pad holds changes Craft never confirmed: the in-memory
    /// dirty bit, a block diff against the last confirmed sidecar (the bit
    /// is forgotten on relaunch, the plan is not — same rule the pull
    /// decides by), or a title the baseline never recorded. Unknown
    /// baselines read as unconfirmed: a legacy mapping's first trash-hit
    /// keeps its text rather than deleting on a maybe.
    private func hasUnconfirmedEdits(_ padID: UUID) -> Bool {
        if dirtyPadIDs.contains(padID) { return true }
        guard let document,
              let pad = document.notes.first(where: { $0.id == padID })
        else { return false }
        let slices = CraftBlockSplitter.slices(in: pad.text)
        if !sidecar(for: padID).pushPlan(for: slices).isEmpty { return true }
        guard let baseline = syncedTitle(for: padID) else {
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
        guard craftDocumentID(for: padID) != nil else { return !slices.isEmpty }
        if pad.name != syncedTitle(for: padID) { return true }
        return !sidecar(for: padID).pushPlan(for: slices).isEmpty
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

    /// Unhide without the spurious persist a bare remove would spend on every
    /// select: the set only writes when an id actually leaves it.
    private func unhide(_ id: UUID) {
        if closedNoteIDs.contains(id) {
            closedNoteIDs.remove(id)
        }
    }

    private static func decodedClosedNoteIDs(_ data: Data?) -> Set<UUID> {
        guard let data,
              let ids = try? JSONDecoder().decode(Set<UUID>.self, from: data)
        else { return [] }
        return ids
    }

    private func persistClosedNoteIDs() {
        guard let data = try? JSONEncoder().encode(closedNoteIDs) else { return }
        defaults.set(data, forKey: closedTabsKey)
    }

    // MARK: - Craft block-id sidecar

    /// The sidecar for a pad, or empty when it never synced. Bytes that do
    /// not decode read as never-synced — like the document, a failed decode
    /// is bytes we do not understand, never bytes we may replace.
    public func sidecar(for id: UUID) -> BlockSidecar {
        storedSidecars()[id.uuidString] ?? BlockSidecar()
    }

    public func storeSidecar(_ sidecar: BlockSidecar, for id: UUID) {
        if isStoredSidecarsUnreadable { rescueUnreadableSidecars() }
        sidecarMap().set(sidecar, for: id.uuidString)
    }

    public func dropSidecar(for id: UUID) {
        guard storedSidecars()[id.uuidString] != nil else { return }
        sidecarMap().set(nil, for: id.uuidString)
    }

    private func sidecarMap() -> DefaultsMap<BlockSidecar> {
        DefaultsMap(defaults: defaults, key: sidecarKey)
    }

    private func storedSidecars() -> [String: BlockSidecar] {
        if sidecarMap().hasUndecodableBytes { isStoredSidecarsUnreadable = true }
        return sidecarMap().load()
    }

    /// Bytes we cannot read are still some later build's recovery path. Copied
    /// aside before the healing write lands on top, like the document — and
    /// only once, so a second corruption never eats the first copy.
    private func rescueUnreadableSidecars() {
        isStoredSidecarsUnreadable = false
        guard let stored = defaults.object(forKey: sidecarKey),
              defaults.object(forKey: sidecarsRescueKey) == nil
        else { return }
        defaults.set(stored, forKey: sidecarsRescueKey)
    }

    // MARK: - Craft push

    /// The Craft document a pad syncs to, if one was provisioned. Mapped
    /// automatically on first push of a non-empty pad (ccp-0gek) — never by
    /// hand — so an unmapped pad is simply one whose document does not exist
    /// yet. Like retention and selection this is config, never note text.
    public func craftDocumentID(for id: UUID) -> String? {
        storedCraftDocuments()[id.uuidString]
    }

    public func setCraftDocumentID(_ docID: String, for id: UUID) {
        craftDocumentMap().set(docID, for: id.uuidString)
        // A new sync relationship gets fresh chances.
        consecutivePushFailures = 0
        pushThrottledUntil = nil
    }

    public func dropCraftDocumentID(for id: UUID) {
        let map = craftDocumentMap()
        guard map.load()[id.uuidString] != nil else { return }
        map.set(nil, for: id.uuidString)
    }

    /// Create the pad's Craft document. The doc is born EMPTY in `unsorted`
    /// (title = pad name at creation, never renamed after) and the content
    /// follows as the empty-doc first sync in the same round. The mapping
    /// itself lands in pushOnePad, after a liveness re-check — a throw, or a
    /// pad closed mid-create, stores nothing, so a retry never orphans a
    /// document the sidecar does not know and deleted text is never pushed.
    private func provisionCraftDocument(name: String, client: CraftClient) async throws -> String {
        try await client.createDocument(title: name).id
    }

    private func craftDocumentMap() -> DefaultsMap<String> {
        DefaultsMap(defaults: defaults, key: craftDocumentsKey)
    }

    private func storedCraftDocuments() -> [String: String] {
        craftDocumentMap().load()
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
        guard !isPushInFlight else { needsPushAfterFlight = true; return }
        guard let baseURL = craftBaseURL() else { return }
        isPushInFlight = true
        defer {
            isPushInFlight = false
            if needsPushAfterFlight {
                needsPushAfterFlight = false
                scheduleCraftPush()
            }
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
            craftDocumentID(for: $0) != nil && padNeedsPush($0)
        }
        let attempted: [UUID]
        if mappedWriters.isEmpty {
            attempted = Array(dirtyPadIDs)
        } else if let trashed = try? await client.trashedDocumentIDs(),
                  craftBaseURL() == baseURL {
            for padID in Array(dirtyPadIDs) where craftBaseURL() == baseURL {
                if let docID = craftDocumentID(for: padID), trashed.contains(docID) {
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
        var docID = craftDocumentID(for: padID)
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
            setCraftDocumentID(newID, for: padID)
            // Born named: the creation title IS the pad's name, so the title
            // baseline starts converged — no rename PUT follows.
            storeSyncedTitle(pad.name, for: padID)
            docID = newID
        }
        guard let docID else { return true }
        // Unknown baseline reads as dirty: the push converges it. (A legacy
        // mapping the pull saw first already recorded Craft's title there, so
        // this only fires for pads the push reaches before any pull.)
        let titleDirty = pad.name != syncedTitle(for: padID)
        let sidecar = sidecar(for: padID)
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
            if !confirmed.isEmpty { storeSyncedTitle(confirmed, for: padID) }
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
        storeSidecar(newSidecar, for: padID)
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

    // MARK: - Craft title sync

    /// The last Craft-confirmed title for a pad, if one was recorded. A pad
    /// whose name differs from this is title-dirty in the push direction; a
    /// fetch whose root differs is dirty in the pull direction. Unknown reads
    /// as dirty — the push converges it — except on the pull's first sight of
    /// a legacy mapping, which records rather than overwrites (see reconcile).
    public func syncedTitle(for id: UUID) -> String? {
        syncedTitleMap().load()[id.uuidString]
    }

    public func storeSyncedTitle(_ title: String?, for id: UUID) {
        syncedTitleMap().set(title, for: id.uuidString)
    }

    public func dropSyncedTitle(for id: UUID) {
        syncedTitleMap().set(nil, for: id.uuidString)
    }

    private func syncedTitleMap() -> DefaultsMap<String> {
        DefaultsMap(defaults: defaults, key: syncedTitleKey)
    }

    /// When the pad was last renamed locally. Nil for never-renamed: ties and
    /// unknown clocks break toward the pad, so an unknown date reads as
    /// local-wins rather than a guess.
    public func titleRenameDate(for id: UUID) -> Date? {
        titleRenameDateMap().load()[id.uuidString]
    }

    public func storeTitleRenameDate(_ date: Date?, for id: UUID) {
        titleRenameDateMap().set(date, for: id.uuidString)
    }

    public func dropTitleRenameDate(for id: UUID) {
        titleRenameDateMap().set(nil, for: id.uuidString)
    }

    private func titleRenameDateMap() -> DefaultsMap<Date> {
        DefaultsMap(defaults: defaults, key: titleRenamedAtKey)
    }

    // MARK: - Craft pull

    /// The last server moment a pad agreed with Craft, if one was recorded.
    public func syncedAt(for id: UUID) -> Date? {
        syncedAtMap().load()[id.uuidString]
    }

    private func storeSyncedAt(_ date: Date?, for id: UUID) {
        guard let date else { return }
        syncedAtMap().set(date, for: id.uuidString)
    }

    private func syncedAtMap() -> DefaultsMap<Date> {
        DefaultsMap(defaults: defaults, key: syncedAtKey)
    }

    /// Conflict-copy ids for a pad, pruned to blocks Craft still holds.
    func stashIDs(for id: UUID) -> Set<String> {
        Set(stashMap().load()[id.uuidString] ?? [])
    }

    private func storeStashIDs(_ ids: Set<String>, for id: UUID) {
        stashMap().set(ids.isEmpty ? nil : Array(ids), for: id.uuidString)
    }

    private func stashMap() -> DefaultsMap<[String]> {
        DefaultsMap(defaults: defaults, key: stashKey)
    }

    /// Test seam: closing a note must leave no per-pad sync state behind.
    /// UUIDs never reuse and pulls only visit mapped pads, so anything kept
    /// leaks forever — and its Craft copies surface nowhere once the mapping
    /// and records are gone.
    func dropStashIDs(for id: UUID) {
        stashMap().set(nil, for: id.uuidString)
    }

    func dropSyncedAt(for id: UUID) {
        syncedAtMap().set(nil, for: id.uuidString)
    }

    // MARK: - Craft conflict records

    /// Bumped on every record/dismiss/drop. The records live in UserDefaults,
    /// which observation cannot see — views read it through `conflicts(for:)`
    /// so they refresh when the set changes (a background pull recording, a
    /// dismiss emptying the list).
    private(set) var conflictsVersion = 0

    /// Conflicts stashed for a pad, newest first. Empty when none ever
    /// stashed — pins from before records existed list nothing.
    public func conflicts(for id: UUID) -> [ConflictRecord] {
        _ = conflictsVersion
        return conflictsMap().load()[id.uuidString] ?? []
    }

    /// Forgets one conflict record. The Craft-side copy and its sidecar pins
    /// stay: forgetting must never re-echo the copy into the pad.
    public func dismissConflict(_ recordID: UUID, for id: UUID) {
        let kept = conflicts(for: id).filter { $0.id != recordID }
        conflictsMap().set(kept.isEmpty ? nil : kept, for: id.uuidString)
        conflictsVersion += 1
    }

    public func dropConflicts(for id: UUID) {
        conflictsMap().set(nil, for: id.uuidString)
        conflictsVersion += 1
    }

    /// Conflicts kept per pad. More than a handful of lost versions stops
    /// informing and starts hoarding; Craft holds the full history anyway.
    private static let maximumConflictsPerPad = 5

    /// Test seam: the pull spends this on a landed stash.
    func recordConflict(slices: [String], date: Date?, for id: UUID) {
        let record = ConflictRecord(date: date, slices: slices)
        conflictsMap().set(
            Array(([record] + conflicts(for: id)).prefix(Self.maximumConflictsPerPad)),
            for: id.uuidString)
        conflictsVersion += 1
    }

    private func conflictsMap() -> DefaultsMap<[ConflictRecord]> {
        DefaultsMap(defaults: defaults, key: conflictsKey)
    }

    /// Pull every mapped pad: one clock read, one trash listing, then one
    /// block fetch each. A failed clock verifies nothing — the pads stay
    /// exactly as they are, locked, until a retry proves Craft reachable —
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
        isSyncVerified = false
        isSyncCheckFailed = false
        let client = CraftClient(baseURL: baseURL, transport: craftTransport)
        let space = try? await client.checkConnection()
        // Stale or cancelled rounds touch nothing — not even the deep-link
        // cache a cancelled clock would otherwise clear below.
        guard craftBaseURL() == baseURL, !Task.isCancelled else { return }
        // The deep link's address refreshes with the clock read the pull
        // already pays for — no extra request when the button is pressed.
        storeCraftSpaceID(space?.spaceID)
        let serverTime = space?.serverTime
        guard space != nil else {
            isSyncCheckFailed = true
            // One transient 500 at open must not lock the whole session:
            // retry while the panel is up. A later activate or credential
            // change cancels this and starts its own round.
            schedulePullRetry()
            return
        }
        // The credential changed mid-flight: the observer already started a
        // fresh pull for the new space, so this round stands down rather
        // than attesting — or deleting for — a URL it never used.
        guard craftBaseURL() == baseURL, !Task.isCancelled else { return }
        let mappedPadIDs = storedCraftDocuments().keys.compactMap(UUID.init(uuidString:))
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
                if let docID = craftDocumentID(for: padID), trashed.contains(docID) {
                    settleTrashedPad(padID)
                }
            }
        }
        for padID in storedCraftDocuments().keys.compactMap(UUID.init(uuidString:)) {
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
        guard let docID = craftDocumentID(for: padID) else { return }
        let fetched = try await client.fetchDocument(documentID: docID)
        guard !Task.isCancelled else { return }
        // Re-read after the fetch: keystrokes interleave with the await, and
        // deciding on pre-fetch text strands them between the stash and the
        // adopt — in neither the pad nor the Craft copy.
        guard let document,
              let pad = document.notes.first(where: { $0.id == padID })
        else { return }
        let remoteIDs = Set(fetched.blocks.map(\.id))
        switch CraftPull.decide(local: pad.text, sidecar: sidecar(for: padID),
                                remote: fetched.blocks, stashIDs: stashIDs(for: padID)) {
        case .converged:
            storeSyncedAt(serverTime, for: padID)
            dirtyPadIDs.remove(padID)
        case .adopt(let text, let newSidecar):
            adoptRemote(padID: padID, text: text, sidecar: newSidecar)
            storeStashIDs(stashIDs(for: padID).intersection(remoteIDs), for: padID)
            storeSyncedAt(serverTime, for: padID)
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
            let stashed = stashIDs(for: padID).intersection(remoteIDs).union(echo.map(\.id))
            storeStashIDs(stashed, for: padID)
            // The popover lists what was preserved and when; recorded only
            // for the copy that actually landed.
            recordConflict(slices: stash, date: serverTime, for: padID)
            // Re-read after the POST: adopting now would overwrite keystrokes
            // newer than the stash and clear their dirty bit. Leave everything
            // — the stash just posted is their safety copy, and the next pull
            // stashes the fresh text the same way. (`document` above is the
            // pre-POST snapshot; the live state is re-read here.)
            guard self.document?.notes.first(where: { $0.id == padID })?.text == pad.text
            else { return }
            // The stash pins unwritable: it lives in Craft, never in the
            // pad, so the next push must route around it rather than
            // delete what it cannot see.
            var sidecar = seeded
            for item in echo {
                sidecar.entries.append(BlockSidecarEntry(
                    id: item.id, fingerprint: BlockSidecar.fingerprint(item.markdown),
                    isWritable: false))
            }
            adoptRemote(padID: padID, text: text, sidecar: sidecar)
            storeSyncedAt(serverTime, for: padID)
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
              craftDocumentID(for: padID) != nil
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
            if let baseline = syncedTitle(for: padID), localName != baseline {
                dirtyPadIDs.insert(padID)
                scheduleCraftPush()
            }
            return
        }
        guard let baseline = syncedTitle(for: padID) else {
            // No baseline: the mapping predates title sync. Craft's title is
            // the record; a differing pad name pushes local on the next round
            // — pad wins, because the tab strip is the daily surface and the
            // divergence almost always came from a local rename (the ccp-o2dh
            // complaint), not from a deliberate Craft-side rename.
            storeSyncedTitle(remoteName, for: padID)
            if localName != remoteName {
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
               let renamedAt = titleRenameDate(for: padID),
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
        storeSyncedTitle(next.notes.first(where: { $0.id == padID })?.name ?? title, for: padID)
        storeTitleRenameDate(date ?? Date(), for: padID)
    }

    /// Replace a pad's text and sidecar from a pull. Silent: the replacing
    /// flag keeps the widget from re-dirtying and re-pushing what just
    /// arrived, and the persist lands now rather than on the save debounce.
    private func adoptRemote(padID: UUID, text: String, sidecar: BlockSidecar) {
        guard var document,
              let index = document.notes.firstIndex(where: { $0.id == padID })
        else { return }
        document.notes[index].text = text
        document.notes[index].modifiedAt = Date()
        self.document = document
        notes = document.notes
        if padID == selectedNoteID {
            isReplacingText = true
            self.text = text
            isReplacingText = false
        }
        storeSidecar(sidecar, for: padID)
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
    /// a tab the user has since moved away from.
    func appendDroppedText(_ dropped: String, to noteID: UUID?) {
        let fragment = dropped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fragment.isEmpty, hasLoaded, !isReplacingText,
              let noteID, var document else { return }
        let before = document
        document.appendText(fragment, to: noteID, modifiedAt: Date())
        guard document != before else { return }
        self.document = document
        notes = document.notes
        if noteID == selectedNoteID {
            isReplacingText = true
            text = document.notes.first(where: { $0.id == noteID })?.text ?? text
            isReplacingText = false
        }
        scheduleSave()
        dirtyPadIDs.insert(noteID)
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
           let docID = craftDocumentID(for: selectedNoteID),
           let spaceID = storedCraftSpaceID(),
           let url = Self.craftDocumentURL(spaceID: spaceID, blockID: docID) {
            NSWorkspace.shared.open(url)
        } else {
            openCraft()
        }
    }

    private func storedCraftSpaceID() -> String? {
        guard let data = defaults.data(forKey: craftSpaceIDKey),
              let id = try? JSONDecoder().decode(String.self, from: data),
              !id.isEmpty
        else { return nil }
        return id
    }

    private func storeCraftSpaceID(_ id: String?) {
        guard let id, !id.isEmpty,
              let data = try? JSONEncoder().encode(id)
        else {
            defaults.removeObject(forKey: craftSpaceIDKey)
            return
        }
        defaults.set(data, forKey: craftSpaceIDKey)
    }

    /// Observable for tests: the address the toolbar deep link uses, if a
    /// pull has verified the space.
    var craftSpaceID: String? { storedCraftSpaceID() }

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
