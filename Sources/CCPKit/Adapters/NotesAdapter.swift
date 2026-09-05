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
            if let selectedNoteID { dirtyPadIDs.insert(selectedNoteID) }
            scheduleCraftPush()
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
    @ObservationIgnored nonisolated(unsafe) private var credentialObserver: NSObjectProtocol?
    // The Craft connection URL, read once per process. A Keychain read on
    // every push is a prompt on every focus loss; the credential changes only
    // through Settings, which posts craftCredentialDidChange.
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
    // Push bookkeeping (ccp-2zi.5). The pad-to-document mapping is config,
    // like retention and selection — never note text.
    @ObservationIgnored private let craftDocumentsKey = "scratchpadCraftDocuments"
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
    /// the Keychain or the network.
    @ObservationIgnored internal var craftTransport: (any CraftTransport)?
    @ObservationIgnored internal var craftBaseURLOverride: URL?

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
    /// new space never sees.
    private func observeCraftCredentialChanges() {
        credentialObserver = NotificationCenter.default.addObserver(
            forName: .craftCredentialDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cachedCraftBaseURL = nil
            }
        }
    }

    // MARK: - Lifecycle

    public func activate() {
        loadApplyingRetention()
    }

    public func deactivate() {
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
        dropSidecar(for: id)
        dropCraftDocumentID(for: id)
        dirtyPadIDs.remove(id)
        apply(next)
        return true
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

    /// The Craft document a pad syncs to, if one was mapped. Set today by
    /// hand (`defaults write`); choosing and provisioning documents gets its
    /// own UI once the create shape is confirmed live.
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

    private func craftDocumentMap() -> DefaultsMap<String> {
        DefaultsMap(defaults: defaults, key: craftDocumentsKey)
    }

    private func storedCraftDocuments() -> [String: String] {
        craftDocumentMap().load()
    }

    private func craftBaseURL() -> URL? {
        // Cached: every push otherwise IPCs into the Keychain, which prompts
        // on focus loss under a fresh dev signature. Cleared when the
        // credential is saved or forgotten (see observeCraftCredentialChanges).
        if let cached = cachedCraftBaseURL { return cached }
        let loaded = craftBaseURLOverride ?? (try? KeychainCraftCredentialStore().loadConnectionURL())
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
        // Snapshot: pads clear or fail below, which mutates the set.
        for padID in Array(dirtyPadIDs) {
            do {
                // False is not failure (throw is): the pad was edited
                // mid-flight, so it stays dirty for the follow-up round.
                let pushedClean = try await pushOnePad(padID, client: client)
                if pushedClean {
                    dirtyPadIDs.remove(padID)
                }
            } catch {
                failure = failure ?? error
            }
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
    /// blocks. Skips (no mapping, pad gone, empty plan) clear the dirty bit
    /// silently; edits re-dirty if the pad comes back. A throw keeps the pad
    /// dirty and every later round retries it.
    ///
    /// Returns false when the pad was edited mid-flight: the stored sidecar
    /// describes the pushed text, not the current text, so the pad stays
    /// dirty and the already-scheduled follow-up pushes the new text.
    private func pushOnePad(_ padID: UUID, client: CraftClient) async throws -> Bool {
        guard let document,
              let padText = document.notes.first(where: { $0.id == padID })?.text,
              let docID = craftDocumentID(for: padID)
        else { return true }
        let sidecar = sidecar(for: padID)
        let slices = CraftBlockSplitter.slices(in: padText)
        let plan = sidecar.pushPlan(for: slices)
        guard !plan.isEmpty else { return true }

        var pendingError: Error?
        var putEcho: [CraftBlock] = []
        var echoByInsert: [Int: [CraftBlock]] = [:]
        var deletesConfirmed = plan.deletes.isEmpty
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
            pendingError = error
        }
        storePushOutcome(padID: padID, sidecar: sidecar, text: padText, slices: slices,
                         putEcho: putEcho, postEchoByInsert: echoByInsert,
                         deletesConfirmed: deletesConfirmed)
        if let pendingError { throw pendingError }
        return self.document?.notes.first(where: { $0.id == padID })?.text == padText
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
