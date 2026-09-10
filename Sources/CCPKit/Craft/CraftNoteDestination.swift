// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// The Craft sync bookkeeping store (ccp-2zi.4, step 7 of
/// docs/notes-storage-plan.md §3).
///
/// One pad syncs to potentially several destinations at once, and each backend
/// owns its own bookkeeping keys. This is the Craft backend's store: everything
/// the push/pull engine remembers about Craft — sync bases, document ids, title
/// baselines, stash pins, conflict records, the space id — lives behind it,
/// under unchanged keys and the unchanged persisted format. Craft-shaped on
/// purpose: a vault backend is paths and files with no ids at all, so no
/// second backend conforms to this. The generic operation seam stays deferred
/// (§4.1); this store is what makes adding it later mechanical.
///
/// It is deliberately the storage seam only, not the operation-level protocol
/// §4.1 defers: batching the round into one call would widen the
/// decide-to-apply window past the freshness re-reads, cancellation could not
/// express partial results, and the dirty set the engine reads is coordinator
/// state no store can compute. None of those objections touches per-pad
/// storage, so a second implementation can prove this seam now while the
/// operation shape stays deferred.
protocol CraftSyncStore: AnyObject {
    /// The two texts a pad last agreed on with Craft, or empty when it never
    /// synced. Bytes that do not decode read as never-synced — a failed
    /// decode is bytes we do not understand, never bytes we may replace.
    func base(for id: UUID) -> PadSyncBase
    func storeBase(_ base: PadSyncBase, for id: UUID)
    func dropBase(for id: UUID)

    /// The Craft document a pad syncs to, if one was provisioned.
    func craftDocumentID(for id: UUID) -> String?
    func setCraftDocumentID(_ docID: String, for id: UUID)
    func dropCraftDocumentID(for id: UUID)
    /// Every pad with a provisioned document. Read fresh each round — a pad
    /// deleted mid-round must not be visited from a snapshot.
    var mappedPadIDs: [UUID] { get }

    /// The last Craft-confirmed title per pad, plus when the pad was last
    /// renamed locally. The pair is what makes a rename a syncable change.
    /// Unknown reads as dirty — the push converges it.
    func syncedTitle(for id: UUID) -> String?
    func storeSyncedTitle(_ title: String?, for id: UUID)
    func dropSyncedTitle(for id: UUID)
    func titleRenameDate(for id: UUID) -> Date?
    func storeTitleRenameDate(_ date: Date?, for id: UUID)
    func dropTitleRenameDate(for id: UUID)

    /// The last server moment a pad agreed with Craft. Advisory — what moved
    /// is decided against the recorded base, never the clock. A failed decode
    /// reads as never-synced.
    func syncedAt(for id: UUID) -> Date?
    func storeSyncedAt(_ date: Date?, for id: UUID)
    func dropSyncedAt(for id: UUID)

    /// Legacy conflict-copy block ids: sections an older build appended to
    /// the Craft document. Read-only now — nothing is ever added — so the
    /// copies already in users' documents stay out of the pad without being
    /// deleted from Craft. Empties as the user clears them there.
    func stashIDs(for id: UUID) -> Set<String>
    func dropStashIDs(for id: UUID)

    /// Conflict records for the popover: what each stash preserved and when,
    /// per pad, newest first. Empty when none ever stashed.
    func conflicts(for id: UUID) -> [ConflictRecord]
    func recordConflict(slices: [String], date: Date?, for id: UUID)
    func dismissConflict(_ recordID: UUID, for id: UUID)
    func dropConflicts(for id: UUID)

    /// Pre-replacement copies per pad (ccp-o3k), newest first. The snapshot
    /// is what makes clearing the editor's undo stack on a replacing pull
    /// correct rather than lossy — the pre-pull text is one menu item away,
    /// not gone.
    func snapshots(for id: UUID) -> [PadSnapshot]
    func recordSnapshot(markdown: String, reason: SnapshotReason, date: Date?, for id: UUID)
    func dropSnapshots(for id: UUID)

    /// The space id GET /connection reports: what the per-document deep link
    /// is addressed with. Refreshed on every pull's clock read, cleared with
    /// the credential.
    var craftSpaceID: String? { get }
    func storeCraftSpaceID(_ id: String?)

    /// Every per-pad sync trace, in one place: deleteNote and unmapPad share it,
    /// so the next key never updates one and misses the other. The space id
    /// is per-space, not per-pad, and stays. Snapshots are not sync traces —
    /// local history, kept beside them — so they drop with the pad (deleteNote
    /// calls dropSnapshots alongside), never with the mapping.
    func dropSyncState(for id: UUID)
}

/// The Craft backend behind the seam: the seven per-pad `DefaultsMap`s plus
/// the space id, under the long-standing keys. Keys unchanged,
/// no persisted-format change, no migration.
final class CraftNoteDestination: CraftSyncStore {
    private let defaults: UserDefaults

    // The sync base (ccp-c2x5): pad id to the pair of texts — ours and
    // Craft's — that last agreed. Ours, not upstream's, so it lives under its
    // own key: sync bookkeeping, never note text. A new key, so the
    // superseded `scratchpadCraftSidecars` bytes are simply left alone and a
    // pad with no base seeds from its next fetch.
    private let baseKey = "scratchpadCraftBases"
    private let basesRescueKey = "scratchpadCraftBases.unreadable"
    private var isStoredBasesUnreadable = false
    // Pull bookkeeping (ccp-2zi.6): the last server moment each pad agreed
    // with Craft.
    private let syncedAtKey = "scratchpadCraftSyncedAt"
    // Conflict copies an older build posted into the Craft document
    // (ccp-2zi.6, superseded by ccp-c2x5). Kept as a read-only exclusion
    // list so those sections stay out of the pad; nothing writes to it now.
    private let stashKey = "scratchpadCraftStash"
    // Conflict records for the popover (ccp-omt1): what each stash preserved
    // and when, per pad, newest first. The pins stay the sync's business.
    private let conflictsKey = "scratchpadCraftConflicts"
    // Pre-replacement copies (ccp-o3k): what each pad held before a pull, a
    // conflict merge, or a restore replaced it. Local history under sync
    // bookkeeping's roof — it drops with the pad, never with the mapping.
    private let snapshotsKey = "scratchpadPadSnapshots"
    // Push bookkeeping (ccp-2zi.5). The pad-to-document mapping is config,
    // like selection — never note text.
    private let craftDocumentsKey = "scratchpadCraftDocuments"
    // Title sync (ccp-o2dh): the last Craft-confirmed title per pad, plus
    // when the pad was last renamed locally.
    private let syncedTitleKey = "scratchpadCraftTitles"
    private let titleRenamedAtKey = "scratchpadCraftTitleRenamedAt"
    // The space id GET /connection reports (ccp-xc2j).
    private let craftSpaceIDKey = "scratchpadCraftSpaceID"

    /// Conflicts kept per pad. More than a handful of lost versions stops
    /// informing and starts hoarding; Craft holds the full history anyway.
    private static let maximumConflictsPerPad = 5

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func base(for id: UUID) -> PadSyncBase {
        storedBases()[id.uuidString] ?? PadSyncBase()
    }

    func storeBase(_ base: PadSyncBase, for id: UUID) {
        if isStoredBasesUnreadable { rescueUnreadableBases() }
        baseMap().set(base, for: id.uuidString)
    }

    func dropBase(for id: UUID) {
        guard storedBases()[id.uuidString] != nil else { return }
        baseMap().set(nil, for: id.uuidString)
    }

    private func baseMap() -> DefaultsMap<PadSyncBase> {
        DefaultsMap(defaults: defaults, key: baseKey)
    }

    private func storedBases() -> [String: PadSyncBase] {
        if baseMap().hasUndecodableBytes { isStoredBasesUnreadable = true }
        return baseMap().load()
    }

    /// Bytes we cannot read are still some later build's recovery path. Copied
    /// aside before the healing write lands on top, like the document — and
    /// only once, so a second corruption never eats the first copy.
    private func rescueUnreadableBases() {
        isStoredBasesUnreadable = false
        guard let stored = defaults.object(forKey: baseKey),
              defaults.object(forKey: basesRescueKey) == nil
        else { return }
        defaults.set(stored, forKey: basesRescueKey)
    }

    func craftDocumentID(for id: UUID) -> String? {
        storedCraftDocuments()[id.uuidString]
    }

    func setCraftDocumentID(_ docID: String, for id: UUID) {
        craftDocumentMap().set(docID, for: id.uuidString)
    }

    func dropCraftDocumentID(for id: UUID) {
        let map = craftDocumentMap()
        guard map.load()[id.uuidString] != nil else { return }
        map.set(nil, for: id.uuidString)
    }

    var mappedPadIDs: [UUID] {
        storedCraftDocuments().keys.compactMap(UUID.init(uuidString:))
    }

    private func craftDocumentMap() -> DefaultsMap<String> {
        DefaultsMap(defaults: defaults, key: craftDocumentsKey)
    }

    private func storedCraftDocuments() -> [String: String] {
        craftDocumentMap().load()
    }

    func syncedTitle(for id: UUID) -> String? {
        syncedTitleMap().load()[id.uuidString]
    }

    func storeSyncedTitle(_ title: String?, for id: UUID) {
        syncedTitleMap().set(title, for: id.uuidString)
    }

    func dropSyncedTitle(for id: UUID) {
        syncedTitleMap().set(nil, for: id.uuidString)
    }

    private func syncedTitleMap() -> DefaultsMap<String> {
        DefaultsMap(defaults: defaults, key: syncedTitleKey)
    }

    func titleRenameDate(for id: UUID) -> Date? {
        titleRenameDateMap().load()[id.uuidString]
    }

    func storeTitleRenameDate(_ date: Date?, for id: UUID) {
        titleRenameDateMap().set(date, for: id.uuidString)
    }

    func dropTitleRenameDate(for id: UUID) {
        titleRenameDateMap().set(nil, for: id.uuidString)
    }

    private func titleRenameDateMap() -> DefaultsMap<Date> {
        DefaultsMap(defaults: defaults, key: titleRenamedAtKey)
    }

    func syncedAt(for id: UUID) -> Date? {
        syncedAtMap().load()[id.uuidString]
    }

    func storeSyncedAt(_ date: Date?, for id: UUID) {
        guard let date else { return }
        syncedAtMap().set(date, for: id.uuidString)
    }

    func dropSyncedAt(for id: UUID) {
        syncedAtMap().set(nil, for: id.uuidString)
    }

    private func syncedAtMap() -> DefaultsMap<Date> {
        DefaultsMap(defaults: defaults, key: syncedAtKey)
    }

    func stashIDs(for id: UUID) -> Set<String> {
        Set(stashMap().load()[id.uuidString] ?? [])
    }

    func dropStashIDs(for id: UUID) {
        stashMap().set(nil, for: id.uuidString)
    }

    private func stashMap() -> DefaultsMap<[String]> {
        DefaultsMap(defaults: defaults, key: stashKey)
    }

    func conflicts(for id: UUID) -> [ConflictRecord] {
        conflictsMap().load()[id.uuidString] ?? []
    }

    func recordConflict(slices: [String], date: Date?, for id: UUID) {
        let record = ConflictRecord(date: date, slices: slices)
        conflictsMap().set(
            Array(([record] + conflicts(for: id)).prefix(Self.maximumConflictsPerPad)),
            for: id.uuidString)
    }

    /// Forgetting drops one record. The Craft-side copy and its pins
    /// stay: forgetting must never re-echo the copy into the pad.
    func dismissConflict(_ recordID: UUID, for id: UUID) {
        let kept = conflicts(for: id).filter { $0.id != recordID }
        conflictsMap().set(kept.isEmpty ? nil : kept, for: id.uuidString)
    }

    func dropConflicts(for id: UUID) {
        conflictsMap().set(nil, for: id.uuidString)
    }

    private func conflictsMap() -> DefaultsMap<[ConflictRecord]> {
        DefaultsMap(defaults: defaults, key: conflictsKey)
    }

    /// Snapshots kept per pad. Full markdown each, but pads are short-lived
    /// scratch text — ten copies is the bead's number, not a budget.
    private static let maximumSnapshotsPerPad = 10

    func snapshots(for id: UUID) -> [PadSnapshot] {
        snapshotsMap().load()[id.uuidString] ?? []
    }

    func recordSnapshot(markdown: String, reason: SnapshotReason, date: Date?, for id: UUID) {
        let snapshot = PadSnapshot(date: date, reason: reason, markdown: markdown)
        snapshotsMap().set(
            Array(([snapshot] + snapshots(for: id)).prefix(Self.maximumSnapshotsPerPad)),
            for: id.uuidString)
    }

    func dropSnapshots(for id: UUID) {
        snapshotsMap().set(nil, for: id.uuidString)
    }

    private func snapshotsMap() -> DefaultsMap<[PadSnapshot]> {
        DefaultsMap(defaults: defaults, key: snapshotsKey)
    }

    var craftSpaceID: String? {
        guard let data = defaults.data(forKey: craftSpaceIDKey),
              let id = try? JSONDecoder().decode(String.self, from: data),
              !id.isEmpty
        else { return nil }
        return id
    }

    func storeCraftSpaceID(_ id: String?) {
        guard let id, !id.isEmpty,
              let data = try? JSONEncoder().encode(id)
        else {
            defaults.removeObject(forKey: craftSpaceIDKey)
            return
        }
        defaults.set(data, forKey: craftSpaceIDKey)
    }

    func dropSyncState(for id: UUID) {
        dropBase(for: id)
        dropCraftDocumentID(for: id)
        dropSyncedTitle(for: id)
        dropTitleRenameDate(for: id)
        dropConflicts(for: id)
        dropStashIDs(for: id)
        dropSyncedAt(for: id)
    }
}
