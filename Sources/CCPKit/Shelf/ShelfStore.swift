// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import Combine
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
    public private(set) var isPinned = false

    @ObservationIgnored private let fileStore = JSONFileStore<[ShelfItem]>(
        filename: "shelf.json",
        default: []
    )
    @ObservationIgnored private var persistWork: DispatchWorkItem?

    /// Files for pasted images / GIF data, alongside the clipboard images.
    public static var storeDirectory: URL {
        let base = URL.applicationSupport.appendingPathComponent("ShelfFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public var itemCount: Int { items.count }

    init() {
        items = fileStore.load()
        // Heal missing image files: keep the entry but mark missing on read
        // is the UI's job; persistence just drops what it can't decode.
    }

    // MARK: - Pin

    public func togglePin() { isPinned.toggle() }

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
        guard fileExists(url) || url.isFileURL else { return nil }
        guard canAdd(additional: 1) else { return nil }
        let item = ShelfItem(
            kind: .file,
            title: url.lastPathComponent,
            filePath: url.path
        )
        items.insert(item, at: 0)
        selection = [item.id]
        return item
    }

    public func addText(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canAdd(additional: 1) else { return }
        let item = ShelfItem(kind: .text, title: preview(for: trimmed), text: trimmed)
        items.insert(item, at: 0)
        selection = [item.id]
    }

    public func addLink(_ url: URL) {
        guard canAdd(additional: 1) else { return }
        let item = ShelfItem(kind: .link, title: url.absoluteString, urlString: url.absoluteString)
        items.insert(item, at: 0)
        selection = [item.id]
    }

    public func addImage(_ image: NSImage) {
        guard canAdd(additional: 1) else { return }
        guard let data = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        let filename = UUID().uuidString + ".png"
        let dest = Self.storeDirectory.appendingPathComponent(filename)
        try? png.write(to: dest)
        let item = ShelfItem(kind: .image, title: filename, imageFileName: filename)
        items.insert(item, at: 0)
        selection = [item.id]
    }

    public func addImageData(_ data: Data, ext: String = "png") {
        guard canAdd(additional: 1) else { return }
        let filename = UUID().uuidString + "." + ext
        let dest = Self.storeDirectory.appendingPathComponent(filename)
        try? data.write(to: dest)
        let item = ShelfItem(kind: .image, title: filename, imageFileName: filename)
        items.insert(item, at: 0)
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
            let ordered = resolved.sorted { $0.0 < $1.0 }.map(\.1)
            guard !ordered.isEmpty else { return }
            // Insert in provider order, but at the front so the last provider
            // ends up topmost is wrong — preserve first-dropped-first.
            for item in ordered.reversed() {
                let stored: ShelfItem
                switch item.kind {
                case .file: stored = item
                case .text: stored = item
                case .link: stored = item
                case .image: stored = item
                }
                self.items.insert(stored, at: 0)
            }
            if let first = ordered.first {
                self.selection = [first.id]
            }
        }
    }

    private func resolve(provider: NSItemProvider, completion: @escaping (ShelfItem?) -> Void) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    guard let url, url.isFileURL else { return completion(nil) }
                    let item = ShelfItem(kind: .file, title: url.lastPathComponent, filePath: url.path)
                    completion(item)
                }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.gif.identifier) { data, _ in
                DispatchQueue.main.async {
                    guard let data, !data.isEmpty else { return completion(nil) }
                    let filename = UUID().uuidString + ".gif"
                    let dest = Self.storeDirectory.appendingPathComponent(filename)
                    try? data.write(to: dest)
                    completion(ShelfItem(kind: .image, title: filename, imageFileName: filename))
                }
            }
        } else if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                DispatchQueue.main.async {
                    guard let nsImage = image as? NSImage,
                          let data = nsImage.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: data),
                          let png = rep.representation(using: .png, properties: [:])
                    else { return completion(nil) }
                    let filename = UUID().uuidString + ".png"
                    let dest = Self.storeDirectory.appendingPathComponent(filename)
                    try? png.write(to: dest)
                    completion(ShelfItem(kind: .image, title: filename, imageFileName: filename))
                }
            }
        } else if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    guard let url else { return completion(nil) }
                    if url.isFileURL {
                        completion(ShelfItem(kind: .file, title: url.lastPathComponent, filePath: url.path))
                    } else {
                        completion(ShelfItem(kind: .link, title: url.absoluteString, urlString: url.absoluteString))
                    }
                }
            }
        } else if provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                DispatchQueue.main.async {
                    guard let str = string as? String,
                          !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { return completion(nil) }
                    // If it's a URL string, treat as link
                    if let url = URL(string: str), url.scheme != nil, url.host != nil {
                        completion(ShelfItem(kind: .link, title: str, urlString: str))
                    } else {
                        let preview = String(str.components(separatedBy: .newlines).first?.prefix(36) ?? Substring(str.prefix(36)))
                        completion(ShelfItem(kind: .text, title: preview, text: str))
                    }
                }
            }
        } else {
            DispatchQueue.main.async { completion(nil) }
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

    public func clear() {
        let removed = items
        items.removeAll()
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
                return URL(fileURLWithPath: p)
            case .image:
                guard let n = item.imageFileName else { return nil }
                return Self.storeDirectory.appendingPathComponent(n)
            case .text:
                // Write a temp file so dragging text out still drops a file
                guard let t = item.text else { return nil }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(item.title + ".txt")
                try? t.write(to: url, atomically: true, encoding: .utf8)
                return url
            case .link:
                guard let s = item.urlString else { return nil }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("link.url")
                try? "[InternetShortcut]\nURL=\(s)\n".write(to: url, atomically: true, encoding: .utf8)
                return URL(string: s)
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
        let work = DispatchWorkItem { [fileStore, items] in
            try? fileStore.save(items)
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    public func flush() {
        persistWork?.cancel()
        try? fileStore.save(items)
    }

    // For previews / tests
    public func setItemsForTesting(_ new: [ShelfItem]) {
        items = new
    }
}
