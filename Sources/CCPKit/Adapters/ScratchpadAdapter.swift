// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

// MARK: - Retention

/// How long each scratchpad keeps text that nobody edits. The check runs only
/// when the widget loads, against the stored edit dates, so the feature needs
/// no timer at all. Pulled from Vorssaint's ScratchpadSupport — same interval
/// values, same stored key, so a document written by the floating pad reads
/// correctly here and vice-versa.
public enum ScratchpadRetention: String, CaseIterable, Sendable {
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

    public static func sanitized(_ rawValue: String?) -> ScratchpadRetention {
        guard let rawValue, let retention = ScratchpadRetention(rawValue: rawValue) else {
            return .never
        }
        return retention
    }
}

// MARK: - Markdown blocks

public struct ScratchpadMarkdownBlock: Sendable, Equatable {
    public enum Kind: Equatable, Sendable {
        case paragraph
        case heading(Int)
        case unorderedListItem(depth: Int)
        case orderedListItem(ordinal: Int, depth: Int)
        case quote(depth: Int)
        case code
        case thematicBreak
    }

    public let kind: Kind
    public let containerID: Int?
    public let text: AttributedString
}

// MARK: - Pad & Document

public struct ScratchpadPad: Codable, Equatable, Identifiable, Sendable {
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

/// The whole scratchpad state travels as one small document. Stable ids keep
/// selection independent from names, while array order is the tab order.
public struct ScratchpadDocument: Codable, Equatable, Sendable {
    public static let maximumPadCount = 12
    public static let maximumNameLength = 40

    public var pads: [ScratchpadPad]
    public var selectedID: UUID

    public static func initial(defaultName: String,
                               id: UUID = UUID(),
                               text: String = "",
                               modifiedAt: Date? = nil) -> ScratchpadDocument {
        let name = ScratchpadSupport.nextPadName(defaultName: defaultName, existingNames: [])
        let pad = ScratchpadPad(id: id, name: name, text: text, modifiedAt: text.isEmpty ? nil : modifiedAt)
        return ScratchpadDocument(pads: [pad], selectedID: pad.id)
    }

    public static func decoded(_ data: Data?, defaultName: String) -> ScratchpadDocument? {
        guard let data,
              let decoded = try? JSONDecoder().decode(ScratchpadDocument.self, from: data)
        else { return nil }
        return decoded.sanitized(defaultName: defaultName)
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public func sanitized(defaultName: String) -> ScratchpadDocument {
        var seen = Set<UUID>()
        var cleanPads: [ScratchpadPad] = []
        for pad in pads.prefix(Self.maximumPadCount) where seen.insert(pad.id).inserted {
            let fallback = ScratchpadSupport.nextPadName(defaultName: defaultName,
                                                         existingNames: cleanPads.map(\.name))
            let name = ScratchpadSupport.sanitizedPadName(pad.name)
            cleanPads.append(ScratchpadPad(id: pad.id,
                                           name: name.isEmpty ? fallback : name,
                                           text: pad.text,
                                           modifiedAt: pad.text.isEmpty ? nil : pad.modifiedAt))
        }
        guard !cleanPads.isEmpty else { return .initial(defaultName: defaultName) }
        let selection = cleanPads.contains(where: { $0.id == selectedID }) ? selectedID : cleanPads[0].id
        return ScratchpadDocument(pads: cleanPads, selectedID: selection)
    }

    public func addingPad(defaultName: String, id: UUID = UUID()) -> ScratchpadDocument? {
        guard pads.count < Self.maximumPadCount else { return nil }
        var next = self
        let name = ScratchpadSupport.nextPadName(defaultName: defaultName, existingNames: pads.map(\.name))
        next.pads.append(ScratchpadPad(id: id, name: name, text: "", modifiedAt: nil))
        next.selectedID = id
        return next
    }

    public func selecting(_ id: UUID) -> ScratchpadDocument? {
        guard pads.contains(where: { $0.id == id }) else { return nil }
        var next = self
        next.selectedID = id
        return next
    }

    public func renaming(_ id: UUID, to proposedName: String) -> ScratchpadDocument? {
        let name = ScratchpadSupport.sanitizedPadName(proposedName)
        guard !name.isEmpty, let index = pads.firstIndex(where: { $0.id == id }) else { return nil }
        var next = self
        next.pads[index].name = name
        return next
    }

    public func removing(_ id: UUID) -> ScratchpadDocument? {
        guard pads.count > 1, let index = pads.firstIndex(where: { $0.id == id }) else { return nil }
        var next = self
        next.pads.remove(at: index)
        if selectedID == id {
            next.selectedID = next.pads[min(index, next.pads.count - 1)].id
        }
        return next
    }

    public mutating func updateSelectedText(_ text: String, modifiedAt: Date) {
        guard let index = pads.firstIndex(where: { $0.id == selectedID }),
              pads[index].text != text else { return }
        pads[index].text = text
        pads[index].modifiedAt = text.isEmpty ? nil : modifiedAt
    }

    public mutating func applyRetention(_ retention: ScratchpadRetention, now: Date) {
        for index in pads.indices where ScratchpadSupport.shouldClear(
            lastEdited: pads[index].modifiedAt, now: now, retention: retention
        ) {
            pads[index].text = ""
            pads[index].modifiedAt = nil
        }
    }
}

// MARK: - Support

public enum ScratchpadSupport {
    public static func markdownPreview(_ text: String) -> [ScratchpadMarkdownBlock] {
        guard !text.isEmpty else { return [] }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return [ScratchpadMarkdownBlock(kind: .paragraph, containerID: nil, text: AttributedString(text))]
        }

        var blocks: [ScratchpadMarkdownBlock] = []
        var currentID: Int?
        var currentKind = ScratchpadMarkdownBlock.Kind.paragraph
        var currentContainerID: Int?
        var currentText = AttributedString()

        func finishBlock() {
            guard currentID != nil else { return }
            if currentKind == .code {
                while currentText.characters.last?.isNewline == true {
                    currentText.characters.removeLast()
                }
            }
            blocks.append(ScratchpadMarkdownBlock(kind: currentKind,
                                                  containerID: currentContainerID,
                                                  text: currentText))
            currentText = AttributedString()
        }

        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let blockID = components.first?.identity ?? 0
            if blockID != currentID {
                finishBlock()
                currentID = blockID
                let presentation = markdownBlockPresentation(components)
                currentKind = presentation.kind
                currentContainerID = presentation.containerID
            }
            currentText.append(AttributedString(parsed[run.range]))
        }
        finishBlock()

        return blocks.isEmpty
            ? [ScratchpadMarkdownBlock(kind: .paragraph, containerID: nil, text: AttributedString(text))]
            : blocks
    }

    private static func markdownBlockPresentation(
        _ components: [PresentationIntent.IntentType]
    ) -> (kind: ScratchpadMarkdownBlock.Kind, containerID: Int?) {
        var listDepth = 0
        var listIsOrdered: Bool?
        var listOrdinal = 1
        var quoteDepth = 0
        var containerID: Int?

        for component in components {
            switch component.kind {
            case .header(let level):
                return (.heading(level), nil)
            case .codeBlock:
                return (.code, nil)
            case .thematicBreak:
                return (.thematicBreak, nil)
            case .listItem(let ordinal):
                if listDepth == 0 { listOrdinal = ordinal }
            case .orderedList:
                listDepth += 1
                if listIsOrdered == nil { listIsOrdered = true }
                containerID = component.identity
            case .unorderedList:
                listDepth += 1
                if listIsOrdered == nil { listIsOrdered = false }
                containerID = component.identity
            case .blockQuote:
                quoteDepth += 1
                containerID = component.identity
            case .paragraph, .table, .tableHeaderRow, .tableRow, .tableCell:
                break
            @unknown default:
                break
            }
        }

        if listIsOrdered == true {
            return (.orderedListItem(ordinal: listOrdinal, depth: max(1, listDepth)), containerID)
        }
        if listIsOrdered == false {
            return (.unorderedListItem(depth: max(1, listDepth)), containerID)
        }
        if quoteDepth > 0 { return (.quote(depth: quoteDepth), containerID) }
        return (.paragraph, nil)
    }

    public static func sanitizedPadName(_ name: String) -> String {
        let words = name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return String(words.joined(separator: " ").prefix(ScratchpadDocument.maximumNameLength))
    }

    public static func nextPadName(defaultName: String, existingNames: [String]) -> String {
        let base = sanitizedPadName(defaultName)
        let safeBase = base.isEmpty ? "Scratchpad" : base
        let used = Set(existingNames)
        let firstName = "\(safeBase) 1"
        guard used.contains(safeBase) || used.contains(firstName) else { return firstName }
        for number in 2...ScratchpadDocument.maximumPadCount where !used.contains("\(safeBase) \(number)") {
            return "\(safeBase) \(number)"
        }
        return "\(safeBase) \(existingNames.count + 1)"
    }

    public static func migratedLegacyDocument(text: String,
                                              lastEdited: Date?,
                                              defaultName: String,
                                              retention: ScratchpadRetention,
                                              now: Date,
                                              id: UUID = UUID()) -> ScratchpadDocument {
        var document = ScratchpadDocument.initial(defaultName: defaultName, id: id, text: text, modifiedAt: lastEdited)
        document.applyRetention(retention, now: now)
        return document
    }

    public static func requiresCloseConfirmation(_ pad: ScratchpadPad) -> Bool {
        !pad.text.isEmpty
    }

    public static func shouldClear(lastEdited: Date?, now: Date, retention: ScratchpadRetention) -> Bool {
        guard let limit = retention.maxIdleInterval, let lastEdited else { return false }
        let idle = now.timeIntervalSince(lastEdited)
        return idle > limit
    }

    public static func exportFileName(title: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let safeTitle = sanitizedPadName(title)
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
/// Reads and writes the same UserDefaults keys as the upstream service
/// (`scratchpadDocument`, `scratchpadRetention`) so a note written in one
/// surface is there in the other, and so the retention sweep that runs on load
/// is single-sourced.
@MainActor
@Observable
public final class ScratchpadAdapter {
    // Published for the widget.
    public var text: String = "" {
        didSet {
            guard hasLoaded, !isReplacingText, var document else { return }
            document.updateSelectedText(text, modifiedAt: Date())
            self.document = document
            pads = document.pads
            scheduleSave()
        }
    }

    public private(set) var pads: [ScratchpadPad] = []
    public private(set) var selectedPadID: UUID?
    public private(set) var isPreviewing = false

    public var selectedPadName: String {
        pads.first(where: { $0.id == selectedPadID })?.name ?? defaultName
    }

    public var canCreatePad: Bool { pads.count < ScratchpadDocument.maximumPadCount }
    public var canClosePad: Bool { pads.count > 1 }

    @ObservationIgnored private var document: ScratchpadDocument?
    @ObservationIgnored private var lastSavedDocument: ScratchpadDocument?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var isReplacingText = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let defaultName: String
    @ObservationIgnored private let documentKey = "scratchpadDocument"
    @ObservationIgnored private let retentionKey = "scratchpadRetention"

    public convenience init() {
        self.init(defaults: .standard, defaultName: "Scratchpad")
    }

    public init(defaults: UserDefaults, defaultName: String) {
        self.defaults = defaults
        self.defaultName = defaultName
        loadApplyingRetention()
        observeTermination()
    }

    /// Test seam: in-memory document without touching defaults.
    public init(document: ScratchpadDocument) {
        self.defaults = .standard
        self.defaultName = "Scratchpad"
        hasLoaded = true
        apply(document)
        lastSavedDocument = document
        observeTermination()
    }

    deinit {
        if let observer = terminationObserver {
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
            }
        }
    }

    // MARK: - Lifecycle

    public func activate() {
        loadApplyingRetention()
    }

    public func deactivate() {
        flushSave()
    }

    // MARK: - Document loading

    private func loadApplyingRetention() {
        hasLoaded = true
        if let document, document != lastSavedDocument {
            flushSave()
            return
        }
        let retention = ScratchpadRetention.sanitized(defaults.string(forKey: retentionKey))

        if let stored = defaults.object(forKey: documentKey) {
            let data = stored as? Data
            let decoded = data.flatMap { try? JSONDecoder().decode(ScratchpadDocument.self, from: $0) }
            var loaded = decoded?.sanitized(defaultName: defaultName) ?? .initial(defaultName: defaultName)
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
        let migrated = ScratchpadDocument.initial(defaultName: defaultName)
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
    private func persist(_ document: ScratchpadDocument) -> Bool {
        if document == lastSavedDocument { return true }
        guard let data = document.encoded() else { return false }
        defaults.set(data, forKey: documentKey)
        guard defaults.data(forKey: documentKey) == data else { return false }
        lastSavedDocument = document
        return true
    }

    private func apply(_ document: ScratchpadDocument) {
        self.document = document
        pads = document.pads
        selectedPadID = document.selectedID
        let selectedText = document.pads.first(where: { $0.id == document.selectedID })?.text ?? ""
        isReplacingText = true
        text = selectedText
        isReplacingText = false
        if text.isEmpty { isPreviewing = false }
    }

    // MARK: - Pad verbs

    public func createPad(defaultName: String? = nil) {
        let name = defaultName ?? self.defaultName
        guard let document, let next = document.addingPad(defaultName: name), persist(next) else { return }
        apply(next)
    }

    public func selectPad(_ id: UUID) {
        guard id != selectedPadID, let document, let next = document.selecting(id), persist(next) else { return }
        apply(next)
    }

    public func renamePad(_ id: UUID, to name: String) {
        guard let document, let next = document.renaming(id, to: name), persist(next) else { return }
        apply(next)
    }

    @discardableResult
    public func closePad(_ id: UUID) -> Bool {
        guard let document, let next = document.removing(id), persist(next) else { return false }
        apply(next)
        return true
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
        if isPreviewing {
            isPreviewing = false
        }
        flushSave()
    }

    public func togglePreview() {
        guard !text.isEmpty else { return }
        isPreviewing.toggle()
    }

    public var isEmpty: Bool { text.isEmpty }

    public func exportFileName(date: Date = Date()) -> String {
        ScratchpadSupport.exportFileName(title: selectedPadName, date: date)
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
