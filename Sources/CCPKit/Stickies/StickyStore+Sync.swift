// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Two-way sync for the sticky desk through a single Craft document.
///
/// The desk joins its visible texts with `StickySegments` and syncs the
/// joined markdown as if it were one pad, through the same seam Notes uses
/// (`CraftSyncStore`: sync base, document id, conflict records, history —
/// ccp-2zi.4) and the same block engine (`CraftClient`, `BlockPushPlan`,
/// `CraftPull`, `ThreeWayMerge`). Nothing here speaks the API directly
/// except through those types, so a fix to the push or merge heals both
/// surfaces at once.
///
/// Deliberate deviations from a pad, each for a reason the pad does not
/// share:
///
/// - Geometry (colour, position, size) and archived shells never enter the
///   document: Craft has no model for them, and the pull reconciles texts
///   through visible slots positionally, minting default shells for new
///   segments. A desk that shrank keeps its shells blanked, never deleted.
/// - A trashed document unmaps and keeps the desk, even when converged:
///   deleting layout on a text sync's say-so would destroy what the sync
///   cannot see. The next edit provisions a fresh document like any first
///   edit.
/// - Titles never sync: the document is born "Stickies" and keeps the name.
/// - Dirt is derived (`joinedDeskText != base.localText`, ccp-c2x5), never
///   stored: a bit can go stale against the text it describes, and this
///   cannot.
@MainActor
extension StickyStore {
    /// The one desk's address in the shared destination. Stable across
    /// launches; a UUID no pad will ever collide with.
    static let craftDeskID = UUID(uuidString: "8f3a2b1c-4d5e-4f6a-8b7c-9d0e1f2a3b4c")!

    /// The document's title at provisioning. Born named, never renamed —
    /// title sync stays out of this surface.
    private static let craftDocumentTitle = "Stickies"

    /// Seconds of quiet before an edit pushes. Notes' number, not a second
    /// opinion: two debounces for one server budget would interleave rounds.
    private static let pushDebounce: TimeInterval = 3
    /// Seconds between clock-failure retries while the panel stays up.
    private static let pullRetryDelay: TimeInterval = 30
    private static let pushRetryDelays: [TimeInterval] = [30, 120, 300]

    // MARK: - Status

    public enum SyncStatus: Equatable, Sendable {
        case localOnly
        case syncing
        case offline
        case unsavedChanges
        case failed
        case saved
    }

    /// A saved connection exists. Without one the desk is local-only notes.
    public var hasCraftCredential: Bool {
        if craftCredentialUnavailable { return false }
        if craftBaseURLOverride != nil { return true }
        return cachedCredentialFilePresence
    }

    public var syncStatus: SyncStatus {
        guard hasCraftCredential else { return .localOnly }
        guard isSyncVerified else { return isSyncCheckFailed ? .offline : .syncing }
        if deskTextMoved { return hasPushFailed ? .failed : .unsavedChanges }
        if craftDestination.craftDocumentID(for: Self.craftDeskID) == nil { return .localOnly }
        return .saved
    }

    // MARK: - Lifecycle

    public func activate() {
        refreshCraftCredentialPresence()
        isPanelOpen = true
        pullRetryTask?.cancel()
        pullRetryTask = nil
        // The panel was shut: Craft may have moved under us. Pull now in
        // the background without locking the desk; a failed read changes
        // nothing, and an adopt never lands on unpushed edits without the
        // merge owning them first.
        pullTask?.cancel()
        pullTask = Task { [weak self] in await self?.pullAll() }
    }

    public func deactivate() {
        isPanelOpen = false
        pullTask?.cancel()
        pullTask = nil
        pullRetryTask?.cancel()
        pullRetryTask = nil
        // The next activate re-verifies for status: what Craft did while the
        // panel was shut is unknown again.
        isSyncVerified = false
        flush()
    }

    // MARK: - Desk text

    /// The visible desk as one document's markdown. Archived stickies stay
    /// out, which deletes their segments from the Craft document on the next
    /// push — unlike a pad's hidden tab, whose document stands. Deliberate:
    /// the document mirrors the desk, and the archived text lives on in the
    /// local stickies.json until unarchived, when it rejoins at its slot.
    /// A second Mac therefore cannot restore archived text from Craft, only
    /// this Mac's disk can.
    internal var joinedDeskText: String {
        StickySegments.join(visible.map(\.text))
    }

    /// Whether the desk holds changes Craft never confirmed. Derived, never
    /// stored: compared in our own dialect against the recorded base. An
    /// empty base with syncable slices reads as moved — the push converges
    /// it — while a truly empty desk never provisions a document.
    internal var deskTextMoved: Bool {
        let base = craftDestination.base(for: Self.craftDeskID)
        let joined = joinedDeskText
        guard !base.isEmpty else { return !CraftBlockSplitter.slices(in: joined).isEmpty }
        return joined != base.localText
    }

    /// Whether a push round would spend any request on the desk — the trash
    /// sweep's gate, so no-op rounds cost nothing. Mirrors pushOneDesk's own
    /// checks without provisioning.
    private var deskNeedsPush: Bool {
        guard craftDestination.craftDocumentID(for: Self.craftDeskID) != nil else {
            return !CraftBlockSplitter.slices(in: joinedDeskText).isEmpty
        }
        return deskTextMoved
    }

    internal func deskDidChangeForCraft() {
        guard !isApplyingRemote else { return }
        scheduleCraftPush()
    }

    // MARK: - Credential

    internal func refreshCraftCredentialPresence() {
        cachedCredentialFilePresence =
            (try? FileCraftCredentialStore().loadConnectionURL()) != nil
    }

    internal func observeCraftCredentialChanges() {
        credentialObserver = NotificationCenter.default.addObserver(
            forName: .craftCredentialDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cachedCraftBaseURL = nil
                self.refreshCraftCredentialPresence()
                self.isSyncVerified = false
                self.isSyncCheckFailed = false
                self.lastPushErrorDescription = nil
                self.pullTask?.cancel()
                self.pullTask = nil
                self.pullRetryTask?.cancel()
                self.pullRetryTask = nil
                if self.isPanelOpen {
                    self.pullTask = Task { [weak self] in await self?.pullAll() }
                }
            }
        }
    }

    private func craftBaseURL() -> URL? {
        if craftCredentialUnavailable { return nil }
        if let cached = cachedCraftBaseURL { return cached }
        let loaded = craftBaseURLOverride ?? (try? FileCraftCredentialStore().loadConnectionURL())
        cachedCraftBaseURL = loaded
        return loaded
    }

    // MARK: - Push

    private func scheduleCraftPush() {
        // The retry task is deliberately NOT cancelled here: an edit during
        // backoff must not eat the only scheduled healing.
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
    /// throttle window. Coalesces with an in-flight push rather than running
    /// beside it.
    internal func flushCraftPush() async {
        pushTask?.cancel()
        pushTask = nil
        pushRetryTask?.cancel()
        pushRetryTask = nil
        await pushNow()
    }

    private func runCraftPush() async {
        pushTask = nil
        if isPushThrottled {
            if pushRetryTask == nil, let until = pushThrottledUntil {
                schedulePushRetry(after: max(until.timeIntervalSinceNow, 0))
            }
            return
        }
        await pushNow()
    }

    internal var isPushThrottled: Bool {
        if let throttledUntil = pushThrottledUntil { Date() < throttledUntil } else { false }
    }

    internal func pushNow() async {
        pushTask = nil
        // One round at a time: a push deciding inside a pull reads a
        // half-written remote as a move, and vice versa (ccp-r3el).
        guard !isPushInFlight, !isPullInFlight else { needsPushAfterFlight = true; return }
        guard let baseURL = craftBaseURL() else { return }
        isPushInFlight = true
        defer {
            isPushInFlight = false
            drainAfterFlight()
        }
        let client = CraftClient(baseURL: baseURL, transport: craftTransport)
        // A trashed doc still answers writes with 200 — pushing would strand
        // desk text inside Craft's trash. Settle first, gated on a round
        // that would actually write, so no-op rounds cost nothing. Unknown
        // trash blocks the round rather than green-lighting it.
        if deskNeedsPush, craftDestination.craftDocumentID(for: Self.craftDeskID) != nil {
            if let trashed = try? await client.trashedDocumentIDs(),
               craftBaseURL() == baseURL {
                if let docID = craftDestination.craftDocumentID(for: Self.craftDeskID),
                   trashed.contains(docID) {
                    // Settle wins the round: unmap and stop, so a trashed
                    // document is not resurrected in the same breath. The
                    // next edit provisions afresh, like any first edit.
                    unmapDesk()
                    return
                }
            } else if craftBaseURL() == baseURL {
                // Unknown trash blocks the round rather than green-lighting
                // it: a blind write strands desk text in a trashed doc. A
                // blocked round backs off like any failed round — silently
                // standing dirty is the silent failure the status exists for.
                recordPushFailure(CraftClientError.unreachable(statusCode: nil))
                return
            } else {
                return
            }
        }
        guard craftBaseURL() == baseURL, deskNeedsPush else {
            // Nothing owed, nothing failed-pending: a no-op round must not
            // leave a stale failure standing past the undo that cleaned it.
            lastPushErrorDescription = nil
            return
        }
        do {
            switch try await pushOneDesk(client: client) {
            case .wrote:
                noteDidSync(Date())
            case .skipped:
                break
            case .dirty:
                // The base is still unseeded: the pull owns it, and the next
                // edit re-fires anyway. Scheduling here would loop every
                // three seconds while the panel is shut, spending trash
                // listings and fetches nobody watches.
                break
            }
            consecutivePushFailures = 0
            pushThrottledUntil = nil
            lastPushErrorDescription = nil
        } catch {
            recordPushFailure(error)
        }
    }

    /// A failed round's bookkeeping in one place: the throw, the
    /// trash-blocked early return, and any future failure share it, so the
    /// status can never miss one.
    private func recordPushFailure(_ error: Error) {
        consecutivePushFailures += 1
        lastPushErrorDescription =
            (error as? CraftClientError ?? .unreachable(statusCode: nil)).pushFailureText
        let delay = retryDelay(for: error)
        pushThrottledUntil = Date().addingTimeInterval(delay ?? Self.pushRetryDelays[2])
        schedulePushRetry(after: delay)
    }

    private enum PushVisit {
        case wrote
        case skipped
        case dirty
    }

    private func pushOneDesk(client: CraftClient) async throws -> PushVisit {
        var joined = joinedDeskText
        var slices = CraftBlockSplitter.slices(in: joined)
        var docID = craftDestination.craftDocumentID(for: Self.craftDeskID)
        var justProvisioned = false
        if docID == nil {
            // Lazy provisioning (ccp-0gek): the doc is born EMPTY and the
            // content follows as the empty-doc first sync below. Nothing
            // syncable, no document — blank shells alone provision nothing.
            guard !slices.isEmpty else { return .skipped }
            let newID = try await client.createDocument(title: Self.craftDocumentTitle).id
            // The create awaited: recompute from the live desk rather than
            // the pre-await snapshot, so keystrokes interleaved with the
            // round are diffed, not stranded.
            joined = joinedDeskText
            slices = CraftBlockSplitter.slices(in: joined)
            craftDestination.setCraftDocumentID(newID, for: Self.craftDeskID)
            consecutivePushFailures = 0
            pushThrottledUntil = nil
            lastPushErrorDescription = nil
            docID = newID
            justProvisioned = true
        }
        guard let docID else { return .skipped }
        // A document not just created, with no agreement on record: wait for
        // the pull to seed the base. Planning from nothing posts the whole
        // desk into a document that may already hold it.
        guard justProvisioned || !craftDestination.base(for: Self.craftDeskID).isEmpty
        else { return .dirty }
        let base = craftDestination.base(for: Self.craftDeskID)
        let plan = BlockPushPlan.plan(from: base, to: slices.map(\.markdown))
        guard !plan.isEmpty else { return .skipped }

        var pendingError: Error?
        var createdIDs: Set<String> = []
        do {
            if !plan.updates.isEmpty {
                _ = try await client.updateBlocks(plan.updates)
            }
            for group in groupedInserts(plan.inserts) {
                let headSibling = group.first?.afterID == nil ? base.blocks.first?.id : nil
                let echo = try await client.postBlocks(group, documentID: docID,
                                                       headSiblingID: headSibling)
                createdIDs.formUnion(echo.map(\.id))
            }
            if !plan.deletes.isEmpty {
                try await client.deleteBlocks(plan.deletes)
            }
        } catch {
            // Recorded, never skipped: the legs before the throw confirmed
            // writes a retry must not replay (a re-POST duplicates), and the
            // read-back is what the next plan diffs from. Backpressure still
            // stops the round — it just stops it after recording.
            pendingError = error
        }
        // Recorded whether or not the round landed whole: what the read-back
        // shows is what Craft holds, and a POST that succeeded inside a
        // failed round must never be replayed.
        await recordBase(pushed: pendingError == nil ? joined : nil,
                         docID: docID, client: client,
                         known: Set(base.blocks.map(\.id)).union(createdIDs))
        if let pendingError { throw pendingError }
        // Past the legs with no throw, every attempted write confirmed —
        // unless the desk moved mid-flight, which stays dirty for the
        // follow-up the defer already armed.
        return joinedDeskText == joined ? .wrote : .dirty
    }

    /// Read the document back and record it, with the text that was pushed,
    /// as the new agreement. Whatever Craft answers here IS what Craft
    /// holds, however the round went. `known` names every block this round
    /// either started with or created — anything else appeared in Craft
    /// while the round was away and must read as a remote move on the next
    /// pull, never as agreement here.
    private func recordBase(pushed: String?, docID: String,
                            client: CraftClient, known: Set<String>) async {
        guard let fetched = try? await client.fetchDocument(documentID: docID) else { return }
        let blocks = PadSyncBase.remote(fetched.blocks,
                                        excluding: craftDestination.stashIDs(for: Self.craftDeskID))
            .filter { known.contains($0.id) }
        let base = PadSyncBase(localText: pushed ?? CraftPull.join(blocks.map(\.markdown)),
                               blocks: blocks)
        craftDestination.storeBase(base, for: Self.craftDeskID)
    }

    private func groupedInserts(_ inserts: [BlockInsert]) -> [[BlockInsert]] {
        var order: [String?] = []
        var groups: [String?: [BlockInsert]] = [:]
        for insert in inserts {
            if groups[insert.afterID] == nil { order.append(insert.afterID) }
            groups[insert.afterID, default: []].append(insert)
        }
        return order.compactMap { groups[$0] }
    }

    private func retryDelay(for error: Error) -> TimeInterval? {
        switch error as? CraftClientError {
        case .rateLimited(let retryAfter):
            return min(max(retryAfter ?? Self.pushRetryDelays[0], 5), Self.pushRetryDelays[2])
        case .unreachable, nil:
            let step = min(consecutivePushFailures - 1, Self.pushRetryDelays.count - 1)
            guard consecutivePushFailures <= Self.pushRetryDelays.count else { return nil }
            return Self.pushRetryDelays[max(step, 0)]
        }
    }

    private func schedulePushRetry(after delay: TimeInterval?) {
        guard let delay else { pushRetryTask = nil; return }
        pushRetryTask?.cancel()
        pushRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.pushRetryTask = nil
            await self?.runCraftPush()
        }
    }

    // MARK: - Pull

    internal func pullAll(fromRetry: Bool = false) async {
        if fromRetry {
            guard pullRetryTask != nil else { return }
        } else {
            pullRetryTask?.cancel()
            pullRetryTask = nil
        }
        guard let baseURL = craftBaseURL() else { return }
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
        guard craftBaseURL() == baseURL, !Task.isCancelled else { return }
        let serverTime = space?.serverTime
        guard space != nil else {
            isSyncCheckFailed = true
            schedulePullRetry()
            return
        }
        guard craftBaseURL() == baseURL, !Task.isCancelled else { return }
        // Remote deletes never delete layout: a trashed document unmaps and
        // keeps the desk (see the type comment). Membership only — a failed
        // trash read skips the pass rather than unmapping.
        if let docID = craftDestination.craftDocumentID(for: Self.craftDeskID),
           let trashed = try? await client.trashedDocumentIDs(),
           craftBaseURL() == baseURL, !Task.isCancelled,
           trashed.contains(docID) {
            unmapDesk()
        }
        guard craftBaseURL() == baseURL, !Task.isCancelled else { return }
        if craftDestination.craftDocumentID(for: Self.craftDeskID) != nil {
            try? await pullOneDesk(client: client, serverTime: serverTime)
        }
        guard craftBaseURL() == baseURL, !Task.isCancelled else { return }
        isSyncVerified = true
    }

    private func schedulePullRetry() {
        pullRetryTask?.cancel()
        pullRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pullRetryDelay))
            guard !Task.isCancelled else { return }
            await self?.pullAll(fromRetry: true)
        }
    }

    private func pullOneDesk(client: CraftClient, serverTime: Date?) async throws {
        guard let docID = craftDestination.craftDocumentID(for: Self.craftDeskID) else { return }
        let fetched = try await client.fetchDocument(documentID: docID)
        guard !Task.isCancelled else { return }
        // Re-read after the fetch: keystrokes interleave with the await, and
        // deciding on pre-fetch text strands them between the merge and the
        // adopt.
        let local = joinedDeskText
        switch CraftPull.decide(local: local, base: craftDestination.base(for: Self.craftDeskID),
                                remote: fetched.blocks,
                                stashIDs: craftDestination.stashIDs(for: Self.craftDeskID)) {
        case .converged:
            noteDidSync(serverTime)
        case .seed(let base):
            // First sight of this desk: start remembering, move nothing.
            craftDestination.storeBase(base, for: Self.craftDeskID)
        case .adopt(let text, let base):
            adoptRemote(segments: StickySegments.split(text), base: base,
                        snapshotReason: .pull, snapshotDate: serverTime)
            noteDidSync(serverTime)
        case .merged(let text, let hadConflict, let remoteText, let base):
            // Both sides moved and the two edits combined. Only the base's
            // remote side advances: Craft's move is in the desk now, but the
            // merged text is not in Craft until the push lands.
            craftDestination.storeBase(base, for: Self.craftDeskID)
            if hadConflict {
                // Ours stands and Craft's version stays reachable in history —
                // never written back into the user's document.
                craftDestination.recordConflict(slices: [remoteText], date: serverTime,
                                                for: Self.craftDeskID)
                craftDestination.recordSnapshot(markdown: remoteText, reason: .conflict,
                                                date: serverTime, for: Self.craftDeskID)
            }
            adoptRemote(segments: StickySegments.split(text), base: nil,
                        snapshotReason: .pull, snapshotDate: serverTime)
            scheduleCraftPush()
        case .skip:
            break
        }
    }

    /// Replace the desk's texts from a pull, shells standing. Silent: the
    /// applying flag keeps the desk from re-dirtying what just arrived. The
    /// agreement records the desk's own joined text as the local side — never
    /// the decision's, which speaks Craft's hard-break dialect and would read
    /// as a permanent local edit against the desk's blank-line joins. That
    /// asymmetry is exactly what the base's pair is for.
    private func adoptRemote(segments: [String], base: PadSyncBase?,
                             snapshotReason: SnapshotReason, snapshotDate: Date?) {
        let current = joinedDeskText
        let next = StickySegments.join(segments)
        if current != next, !current.isEmpty {
            // The pre-pull desk survives in history, like every replacing
            // pull on the pads.
            craftDestination.recordSnapshot(markdown: current, reason: snapshotReason,
                                            date: snapshotDate, for: Self.craftDeskID)
        }
        setStickiesFromRemote(segments)
        if let base {
            craftDestination.storeBase(PadSyncBase(localText: joinedDeskText,
                                                   blocks: base.blocks),
                                       for: Self.craftDeskID)
        }
    }

    // MARK: - Shared outcomes

    private func noteDidSync(_ date: Date?) {
        craftDestination.storeSyncedAt(date, for: Self.craftDeskID)
    }

    /// Re-run rounds that yielded to a finished one: a deferred push
    /// debounces as usual, a deferred pull runs while the panel is up.
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

    private func schedulePull() {
        pullTask?.cancel()
        pullTask = Task { [weak self] in await self?.pullAll() }
    }

    /// Drop the sync mapping and keep the desk: text, shells and selection
    /// stand, local-only. The next edit provisions a fresh Craft document
    /// like any first edit. History stays — it is the way back into text
    /// that no longer exists, and the desk survives.
    private func unmapDesk() {
        craftDestination.dropSyncState(for: Self.craftDeskID)
        // Unmapped pads owe no push: a stale failure must not brand the next
        // edit's fresh document before it is ever attempted.
        lastPushErrorDescription = nil
    }
}
