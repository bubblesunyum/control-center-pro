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
        didSet { schedulePersist() }
    }

    /// A sticky's delete confirmation is up. The panel's Esc handling reads
    /// this so the keystroke cancels the dialog instead of hiding the panel
    /// from under it. View state, never persisted.
    public var isConfirmingDelete = false

    @ObservationIgnored private let fileStore: JSONFileStore<[Sticky]>
    @ObservationIgnored private var persistWork: DispatchWorkItem?

    private convenience init() {
        self.init(directory: .applicationSupport)
    }

    /// Test seam: a store backed by a temporary directory rather than the
    /// user's own.
    init(directory: URL) {
        fileStore = JSONFileStore(filename: "stickies.json", default: [], in: directory)
        stickies = Self.tolerantLoad(from: fileStore)
    }

    private static func tolerantLoad(from store: JSONFileStore<[Sticky]>) -> [Sticky] {
        // JSONFileStore.load is atomic: one bad sticky throws and the whole
        // file is moved to *.corrupt. Decode leniently per-item instead.
        guard let data = try? Data(contentsOf: store.url) else { return store.load() }
        if let decoded = try? JSONDecoder().decode([Sticky].self, from: data) {
            return decoded
        }
        struct Failable: Decodable {
            let sticky: Sticky?
            init(from decoder: Decoder) throws { sticky = try? Sticky(from: decoder) }
        }
        if let wrapped = try? JSONDecoder().decode([Failable].self, from: data),
           !wrapped.isEmpty, !wrapped.compactMap(\.sticky).isEmpty {
            return wrapped.compactMap(\.sticky)
        }
        // Nothing salvageable — fall through to load(), which moves the file
        // aside as evidence instead of letting the next flush overwrite it
        // with an empty desk.
        return store.load()
    }

    /// The stickies on the desk, in draw order.
    public var visible: [Sticky] { stickies.filter { !$0.isArchived } }

    /// Archived stickies, most recently archived first.
    public var archived: [Sticky] { stickies.filter(\.isArchived).reversed() }

    /// A new sticky on top, at the given panel-space point.
    @discardableResult
    public func add(x: Double = 0, y: Double = 0) -> Sticky {
        let sticky = Sticky(x: x, y: y)
        stickies.append(sticky)
        return sticky
    }

    public func move(_ id: UUID, toX x: Double, toY y: Double) {
        guard let index = stickies.firstIndex(where: { $0.id == id }) else { return }
        stickies[index] = stickies[index].movedTo(x: x, y: y)
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
    }

    // For previews / tests
    public func setStickiesForTesting(_ new: [Sticky]) {
        stickies = new
    }
}
