// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import Observation

/// Holds the panel-pinned stickies: creates, moves, recolours, archives, and
/// persists them, and tells the desk what to draw.
///
/// Deliberately separate from the Notes widget's store: these are local-only,
/// position is intrinsic to each sticky, and sharing the scratchpad's bytes
/// would put two writers on one document. Draw order is array order — new
/// stickies append on top and nothing ever re-sorts, so depth needs no state.
@MainActor
@Observable
public final class StickyStore {
    public static let shared = StickyStore()

    /// All stickies, archived included, in draw order. The desk filters.
    public private(set) var stickies: [Sticky] = [] {
        didSet {
            schedulePersist()
            deskDidChangeForCraft()
        }
    }

    /// A sticky's delete confirmation is up. The panel's Esc handling reads
    /// this so the keystroke cancels the dialog instead of hiding the panel
    /// from under it. View state, never persisted.
    public var isConfirmingDelete = false

    /// A sticky move or resize is in flight. The controller's mouse-through
    /// hit-test reads committed positions, which trail the finger mid-drag —
    /// re-evaluating it mid-gesture would call the window mouse-through under
    /// a held drag and starve the gesture. View state, never persisted.
    public var isDragging = false

    @ObservationIgnored private let fileStore: JSONFileStore<[Sticky]>
    @ObservationIgnored private var persistWork: DispatchWorkItem?
    /// While true, `stickies` writes come from a Craft pull, not the user:
    /// they persist to disk but never re-dirty the sync. Mirrors
    /// NotesAdapter's `isReplacingText`.
    @ObservationIgnored internal var isApplyingRemote = false

    // MARK: - Craft sync state (the engine lives in StickyStore+Sync.swift)

    /// The desk's Craft-side memory behind the same seam Notes syncs through
    /// (ccp-2zi.4): sync base, document id, conflict records, history. One
    /// fixed desk id addresses all of it — titles stay untouched, so the
    /// title half of the seam simply goes unused.
    @ObservationIgnored internal let craftDestination: any CraftSyncStore
    /// Test seams: scripted transport and a fixed URL, so sync runs without
    /// disk or the network.
    @ObservationIgnored internal var craftTransport: (any CraftTransport)?
    @ObservationIgnored internal var craftBaseURLOverride: URL?
    /// Test seam: reads as unconfigured without touching the real store.
    @ObservationIgnored internal var craftCredentialUnavailable = false
    @ObservationIgnored internal var cachedCraftBaseURL: URL?
    @ObservationIgnored internal var cachedCredentialFilePresence = false
    @ObservationIgnored internal var pushTask: Task<Void, Never>?
    @ObservationIgnored internal var pushRetryTask: Task<Void, Never>?
    @ObservationIgnored internal var pullTask: Task<Void, Never>?
    @ObservationIgnored internal var pullRetryTask: Task<Void, Never>?
    @ObservationIgnored internal var isPushInFlight = false
    @ObservationIgnored internal var isPullInFlight = false
    @ObservationIgnored internal var needsPushAfterFlight = false
    @ObservationIgnored internal var needsPullAfterFlight = false
    @ObservationIgnored internal var consecutivePushFailures = 0
    @ObservationIgnored internal var pushThrottledUntil: Date?
    /// Whether the desk pushed and failed, unconfirmed since. Derived from
    /// the reason below: one fact, one source — a later reset path cannot
    /// clear one and forget the other.
    public var hasPushFailed: Bool { lastPushErrorDescription != nil }
    /// Short human reason for the last push failure.
    public internal(set) var lastPushErrorDescription: String?
    @ObservationIgnored internal var isPanelOpen = false
    /// Whether the latest pull has proven Craft reachable. False until the
    /// first pull lands, and on every activate until its pull finishes.
    public internal(set) var isSyncVerified = false
    /// The last verification failed: a credential is saved but Craft never
    /// answered. Sticky until the next pull succeeds.
    public internal(set) var isSyncCheckFailed = false
    @ObservationIgnored internal var credentialObserver: NSObjectProtocol?

    private convenience init() {
        self.init(directory: .applicationSupport)
    }

    /// Test seam: a store backed by a temporary directory rather than the
    /// user's own.
    init(directory: URL,
         defaults: UserDefaults = .standard,
         destination: (any CraftSyncStore)? = nil) {
        fileStore = JSONFileStore(filename: "stickies.json", default: [], in: directory)
        stickies = fileStore.tolerantLoad()
        self.craftDestination = destination ?? CraftNoteDestination(defaults: defaults)
        refreshCraftCredentialPresence()
        observeCraftCredentialChanges()
    }

    deinit {
        if let observer = credentialObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// How far a Craft-minted shell cascades from the note on top, so it
    /// never lands exactly over its parent. Points, like every geometry
    /// here — and local to the store, since CCPUI's own cascade answers a
    /// different surface.
    internal static let remoteCascadeStep: Double = 16

    /// The stickies on the desk, in draw order.
    public var visible: [Sticky] { stickies.filter { !$0.isArchived } }

    /// Archived stickies, most recently archived first.
    public var archived: [Sticky] { stickies.filter(\.isArchived).reversed() }

    /// A new sticky on top, at the given panel-space point — measured from
    /// the trailing edge, like every other sticky position.
    @discardableResult
    public func add(trailingX: Double = 0, y: Double = 0) -> Sticky {
        let sticky = Sticky(trailingX: trailingX, y: y)
        stickies.append(sticky)
        return sticky
    }

    public func move(_ id: UUID, toTrailingX trailingX: Double, toY y: Double) {
        guard let index = stickies.firstIndex(where: { $0.id == id }) else { return }
        stickies[index] = stickies[index].movedTo(trailingX: trailingX, y: y)
    }

    /// A move expressed in leading-space travel: the finger's own units.
    /// The trailing offset absorbs `-dx` here, once, so no gesture negates.
    public func moveBy(_ id: UUID, dx: Double, dy: Double) {
        guard let index = stickies.firstIndex(where: { $0.id == id }) else { return }
        let sticky = stickies[index]
        stickies[index] = sticky.movedTo(trailingX: sticky.trailingX - dx, y: sticky.y + dy)
    }

    /// The one-time conversion of pre-trailing stickies: every stored value
    /// was a distance from the leading edge at the last seat, so the current
    /// seat width turns each into a distance from the trailing edge — every
    /// note lands exactly where it already is. Archived notes convert too,
    /// so an unarchive never restores a mirrored position. One write, so one
    /// render and one debounced persist. Same width twice is the involution
    /// (harmless); zero width converts nothing and reports failure, so the
    /// caller retries at the next seat instead of recording garbage.
    @discardableResult
    public func migrateToTrailingAnchoring(inWidth width: Double) -> Bool {
        guard width > 0 else { return false }
        stickies = stickies.map { sticky in
            var converted = sticky
            converted.convertToTrailingAnchoring(inWidth: width)
            return converted
        }
        return true
    }

    /// A resize commit. One write, on release — the drag itself steers a
    /// transient preview in the view, so a resize never re-renders the desk
    /// or re-arms persistence per pixel. The minimum lives on `resizedTo`.
    public func resize(_ id: UUID, width: Double, height: Double) {
        guard let index = stickies.firstIndex(where: { $0.id == id }) else { return }
        stickies[index] = stickies[index].resizedTo(width: width, height: height)
    }

    public func setText(_ text: String, for id: UUID) {
        guard let index = stickies.firstIndex(where: { $0.id == id }) else { return }
        stickies[index].text = text
    }

    public func setColor(_ color: StickyColor, for id: UUID) {
        guard let index = stickies.firstIndex(where: { $0.id == id }) else { return }
        stickies[index].color = color
    }

    public func delete(_ id: UUID) {
        stickies.removeAll { $0.id == id }
    }

    public func archive(_ id: UUID) {
        guard let index = stickies.firstIndex(where: { $0.id == id }) else { return }
        stickies[index].isArchived = true
    }

    public func unarchive(_ id: UUID) {
        guard let index = stickies.firstIndex(where: { $0.id == id }) else { return }
        stickies[index].isArchived = false
    }

    // MARK: - Persistence

    private func schedulePersist() {
        persistWork?.cancel()
        let snapshot = stickies
        let store = fileStore
        let work = DispatchWorkItem {
            // Off main — encode + atomic write shouldn't ride a drag's frames.
            DispatchQueue.global(qos: .utility).async {
                try? store.save(snapshot)
            }
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    public func flush() {
        persistWork?.cancel()
        let snapshot = stickies
        let store = fileStore
        // Called from willTerminate and panel hide — must drain before exit,
        // so synchronous.
        try? store.save(snapshot)
        // Best-effort only, like NotesAdapter: local bytes are safe above;
        // Craft heals on the next push.
        Task { [weak self] in await self?.flushCraftPush() }
    }

    /// Replace the desk from a Craft pull, keeping every shell: texts flow
    /// through visible slots in order, geometry and colours never move, and
    /// the write persists without re-dirtying the sync.
    internal func setStickiesFromRemote(_ segments: [String]) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        var next = stickies
        let visibleIndices = next.indices.filter { !next[$0].isArchived }
        for (offset, index) in visibleIndices.enumerated() {
            next[index].text = offset < segments.count ? segments[offset] : ""
        }
        // Extra segments mint shells, cascaded from whatever is on top, so a
        // Craft-side addition never lands exactly over its parent. A desk
        // that shrank keeps its shells blanked above rather than deleted:
        // shells carry geometry Craft has no model for, and deleting layout
        // on a text sync's say-so is data loss wearing a sync costume.
        var trailingX = 0.0
        var topY = 0.0
        var hasAnchor = false
        if let last = visibleIndices.last {
            trailingX = next[last].trailingX
            topY = next[last].y
            hasAnchor = true
        }
        for text in segments.dropFirst(visibleIndices.count) {
            if hasAnchor {
                trailingX -= Self.remoteCascadeStep
                topY += Self.remoteCascadeStep
            }
            next.append(Sticky(text: text,
                               trailingX: hasAnchor ? trailingX : 0,
                               y: hasAnchor ? topY : 0))
            hasAnchor = true
        }
        stickies = next
    }

    // For previews / tests
    public func setStickiesForTesting(_ new: [Sticky]) {
        stickies = new
    }
}
