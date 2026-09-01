// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Holds the shelf: accepts drops, persists them, hands pasteboard writers back
/// for dragging out, and tells the floating window when to refit.
///
/// This is a lightweight port of `ShelfService`'s item lifecycle minus its
/// triggers: no global hotkey, no shake detector, no docked pill, no edge
/// peek. The floating window is summoned by the dashboard widget instead, and
/// everything else — pinning, dropping, selecting — stays.
@MainActor
@Observable
public final class ShelfStore {
    public static let shared = ShelfStore()

    public private(set) var items: [ShelfItem] = [] {
        didSet { schedulePersist() }
    }
    public private(set) var selection: Set<UUID> = []
    /// Whether the floating window stays up when focus leaves it. Distinct
    /// from a pinned *item*, which is `ShelfItem.isPinned`.
    public private(set) var keepsWindowOpen = false

    @ObservationIgnored private let fileStore: JSONFileStore<[ShelfItem]>
    @ObservationIgnored private var persistWork: DispatchWorkItem?

    /// Files for pasted images / GIF data, alongside the clipboard images.
    public static var storeDirectory: URL {
        URL.applicationSupport.appendingPathComponent("ShelfFiles", isDirectory: true)
    }

    public static func ensureStoreDirectory() {
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
    }

    public var itemCount: Int { items.count }

    private convenience init() {
        self.init(directory: .applicationSupport)
    }

    /// Test seam: a shelf backed by a temporary directory rather than the
    /// user's own.
    init(directory: URL) {
        fileStore = JSONFileStore(filename: "shelf.json", default: [], in: directory)
        items = Self.pinnedFirst(Self.tolerantLoad(from: fileStore))
    }

    private static func tolerantLoad(from store: JSONFileStore<[ShelfItem]>) -> [ShelfItem] {
        // JSONFileStore.load is atomic: one bad item throws and the whole
        // file is moved to *.corrupt. Decode leniently per-item instead.
        guard let data = try? Data(contentsOf: store.url) else { return store.load() }
        if let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) {
            return decoded
        }
        // Lenient: ignore items whose kind or required fields fail.
        struct Failable: Decodable { let item: ShelfItem?; init(from d: Decoder) throws { item = try? ShelfItem(from: d) } }
        if let wrapped = try? JSONDecoder().decode([Failable].self, from: data) {
            return wrapped.compactMap(\.item)
        }
        return store.load()
    }

    // MARK: - Pin

    public func toggleKeepsWindowOpen() { keepsWindowOpen.toggle() }

    /// Pins an item, or unpins it. Pinned items sort ahead of the rest and
    /// Clear leaves them behind — the shelf is a staging area, and a pin is how
    /// something says it is staying.
    public func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned.toggle()
        items = Self.pinnedFirst(items)
    }

    public var hasUnpinnedItems: Bool { items.contains { !$0.isPinned } }

    /// Pinned ahead of unpinned, each group keeping the order it already had.
    private static func pinnedFirst(_ items: [ShelfItem]) -> [ShelfItem] {
        items.filter(\.isPinned) + items.filter { !$0.isPinned }
    }

    // MARK: - Selection

    public func toggleSelection(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection = [id]
        }
    }

    public func extendSelection(to id: UUID) {
        // Simple toggle for now; full range logic would need ordered ids.
        toggleSelection(id)
    }

    public func clearSelection() { selection.removeAll() }
    public func selectAll() { selection = Set(items.map(\.id)) }

    // MARK: - Add

    @discardableResult
    public func addFile(url: URL) -> ShelfItem? {
        guard url.isFileURL, fileExists(url) else { return nil }
        guard canAdd(additional: 1) else { return nil }
        let item = ShelfItem(
            kind: .file,
            title: url.lastPathComponent,
            filePath: url.path
        )
        insert(item)
        return item
    }

    public func addText(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canAdd(additional: 1) else { return }
        insert(ShelfItem(kind: .text, title: preview(for: trimmed), text: trimmed))
    }

    public func addLink(_ url: URL) {
        guard canAdd(additional: 1) else { return }
        insert(ShelfItem(kind: .link, title: url.absoluteString, urlString: url.absoluteString))
    }

    public func addImage(_ image: NSImage) {
        guard canAdd(additional: 1) else { return }
        guard let data = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        let filename = UUID().uuidString + ".png"
        Self.ensureStoreDirectory()
        let dest = Self.storeDirectory.appendingPathComponent(filename)
        do {
            try png.write(to: dest)
        } catch {
            return
        }
        insert(ShelfItem(kind: .image, title: filename, imageFileName: filename))
    }

    public func addImageData(_ data: Data, ext: String = "png") {
        guard canAdd(additional: 1) else { return }
        let filename = UUID().uuidString + "." + ext
        Self.ensureStoreDirectory()
        let dest = Self.storeDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: dest)
        } catch {
            return
        }
        insert(ShelfItem(kind: .image, title: filename, imageFileName: filename))
    }

    /// Newest first, but never ahead of a pin.
    private func insert(_ item: ShelfItem) {
        items.insert(item, at: items.prefix { $0.isPinned }.count)
        selection = [item.id]
    }

    private func preview(for text: String) -> String {
        let firstLine = text.components(separatedBy: .newlines).first ?? text
        return String(firstLine.prefix(36))
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func canAdd(additional: Int) -> Bool {
        // Same cap upstream uses via ShelfPersistenceSupport — 400 leaves.
        items.count + additional <= 400
    }

    // MARK: - Providers

    /// Resolve `NSItemProvider`s as the drop target does: file first, then image
    /// data, then plain URL, then text — matching upstream's `resolveItem`
    /// ordering so a web-image drag prefers the image.
    public func accept(providers: [NSItemProvider]) -> Bool {
        let viable = providers.filter { canResolve($0) }
        guard !viable.isEmpty, canAdd(additional: viable.count) else { return false }
        acceptMixed(providers: viable)
        return true
    }

    private func canResolve(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            || provider.canLoadObject(ofClass: NSString.self)
            || provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier)
    }

    private func acceptMixed(providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var resolved: [(Int, ShelfItem)] = []
        let lock = NSLock()

        for (index, provider) in providers.enumerated() {
            group.enter()
            resolve(provider: provider) { item in
                if let item {
                    lock.lock()
                    resolved.append((index, item))
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ordered = resolved.sorted { $0.0 < $1.0 }.map(\.1)
                guard !ordered.isEmpty else { return }
                // Re-check capacity at insert time — two concurrent drops
                // could have raced the initial canAdd check.
                let remaining = max(0, 400 - self.items.count)
                let toInsert = Array(ordered.prefix(remaining))
                guard !toInsert.isEmpty else { return }
                for item in toInsert.reversed() {
                    self.insert(item)
                }
                if let first = toInsert.first {
                    self.selection = [first.id]
                }
            }
        }
    }

    private func resolve(provider: NSItemProvider, completion: @escaping (ShelfItem?) -> Void) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in
                    guard let url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
                        return completion(nil)
                    }
                    let item = ShelfItem(kind: .file, title: url.lastPathComponent, filePath: url.path)
                    completion(item)
                }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.gif.identifier) { data, _ in
                Task { @MainActor in
                    guard let data, !data.isEmpty else { return completion(nil) }
                    let filename = UUID().uuidString + ".gif"
                    Self.ensureStoreDirectory()
                    let dest = Self.storeDirectory.appendingPathComponent(filename)
                    do {
                        try data.write(to: dest)
                    } catch {
                        return completion(nil)
                    }
                    completion(ShelfItem(kind: .image, title: filename, imageFileName: filename))
                }
            }
        } else if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                Task { @MainActor in
                    guard let nsImage = image as? NSImage,
                          let data = nsImage.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: data),
                          let png = rep.representation(using: .png, properties: [:])
                    else { return completion(nil) }
                    let filename = UUID().uuidString + ".png"
                    Self.ensureStoreDirectory()
                    let dest = Self.storeDirectory.appendingPathComponent(filename)
                    do {
                        try png.write(to: dest)
                    } catch {
                        return completion(nil)
                    }
                    completion(ShelfItem(kind: .image, title: filename, imageFileName: filename))
                }
            }
        } else if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in
                    guard let url else { return completion(nil) }
                    if url.isFileURL {
                        guard FileManager.default.fileExists(atPath: url.path) else { return completion(nil) }
                        completion(ShelfItem(kind: .file, title: url.lastPathComponent, filePath: url.path))
                    } else {
                        completion(ShelfItem(kind: .link, title: url.absoluteString, urlString: url.absoluteString))
                    }
                }
            }
        } else if provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                Task { @MainActor in
                    guard let str = string as? String,
                          !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { return completion(nil) }
                    // If it's a URL string, treat as link
                    if let url = URL(string: str), url.scheme != nil, url.host != nil {
                        completion(ShelfItem(kind: .link, title: str, urlString: str))
                    } else {
                        let preview = self.preview(for: str)
                        completion(ShelfItem(kind: .text, title: preview, text: str))
                    }
                }
            }
        } else {
            Task { @MainActor in completion(nil) }
        }
    }

    // MARK: - Pasteboard (AppKit drag)

    public func accept(pasteboard: NSPasteboard) -> Bool {
        var accepted = false
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            for url in urls where url.isFileURL {
                addFile(url: url)
                accepted = true
            }
            if accepted { return true }
        }
        if let strings = pasteboard.readObjects(forClasses: [NSString.self]) as? [String] {
            for s in strings {
                addText(s)
                accepted = true
            }
        }
        return accepted
    }

    public func canAcceptPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(where: { type in
            [NSPasteboard.PasteboardType.fileURL.rawValue,
             NSPasteboard.PasteboardType.URL.rawValue,
             NSPasteboard.PasteboardType.string.rawValue,
             NSPasteboard.PasteboardType.tiff.rawValue,
             NSPasteboard.PasteboardType.png.rawValue,
             UTType.image.identifier].contains(type.rawValue)
        }) ?? false
    }

    // MARK: - Remove

    public func remove(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        selection.remove(id)
        retire(item)
    }

    public func removeSelected() {
        let removed = items.filter { selection.contains($0.id) }
        items.removeAll { selection.contains($0.id) }
        selection.removeAll()
        for item in removed { retire(item) }
    }

    /// Clears everything the user hasn't pinned. A pin is the one thing that
    /// says "not this one", so honouring it here is the whole point of having it.
    public func clear() {
        let removed = items.filter { !$0.isPinned }
        items.removeAll { !$0.isPinned }
        selection.removeAll()
        for item in removed { retire(item) }
    }

    private func retire(_ item: ShelfItem) {
        guard let name = item.imageFileName else { return }
        let url = Self.storeDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Drag out

    public func fileURLs(for ids: [UUID]) -> [URL] {
        ids.compactMap { id in
            guard let item = items.first(where: { $0.id == id }) else { return nil }
            switch item.kind {
            case .file:
                guard let p = item.filePath else { return nil }
                let url = URL(fileURLWithPath: p)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return url
            case .image:
                guard let n = item.imageFileName else { return nil }
                let url = Self.storeDirectory.appendingPathComponent(n)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return url
            case .text:
                // Write a temp file so dragging text out still drops a file.
                // Use a UUID filename to avoid collisions when two items share
                // the same preview title; sanitize the preview for the
                // user-visible name is not needed — the URL is what Finder
                // consumes.
                guard let t = item.text else { return nil }
                let sanitized = item.title.replacingOccurrences(of: "/", with: ":")
                let filename = "\(sanitized)-\(item.id.uuidString.prefix(8)).txt"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try? t.write(to: url, atomically: true, encoding: .utf8)
                return url
            case .link:
                guard let s = item.urlString, let target = URL(string: s) else { return nil }
                // macOS expects a .webloc (plist); write one so double-click
                // opens the link regardless of consumer.
                let filename = "link-\(item.id.uuidString.prefix(8)).webloc"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                let plist: [String: Any] = ["URL": s]
                if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                    try? data.write(to: url, options: .atomic)
                }
                // Return the file URL we just wrote; the remote URL is not a file.
                if FileManager.default.fileExists(atPath: url.path) { return url }
                return target
            }
        }
    }

    public func pasteboardWriter(for item: ShelfItem) -> NSPasteboardWriting {
        switch item.kind {
        case .file:
            if let p = item.filePath {
                return NSURL(fileURLWithPath: p) as NSPasteboardWriting
            }
            fallthrough
        case .link:
            if let s = item.urlString, let url = URL(string: s) {
                return url as NSURL as NSPasteboardWriting
            }
            fallthrough
        case .text:
            return (item.text ?? item.title) as NSString
        case .image:
            if let n = item.imageFileName {
                let url = Self.storeDirectory.appendingPathComponent(n)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url as NSURL as NSPasteboardWriting
                }
            }
            return (item.title as NSString)
        }
    }

    // MARK: - Persistence

    private func schedulePersist() {
        persistWork?.cancel()
        let snapshot = items
        let store = fileStore
        let work = DispatchWorkItem {
            // Off main — JSON encode + atomic write can be ~3 MB at 400 items.
            DispatchQueue.global(qos: .utility).async {
                try? store.save(snapshot)
            }
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    public func flush() {
        persistWork?.cancel()
        let snapshot = items
        let store = fileStore
        // Called from willTerminate — must drain before exit, off-main not needed
        // there since the process is quitting, but keep it synchronous.
        try? store.save(snapshot)
    }

    // For previews / tests
    public func setItemsForTesting(_ new: [ShelfItem]) {
        items = Self.pinnedFirst(new)
    }
}
