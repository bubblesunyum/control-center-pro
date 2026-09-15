// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import WebKit

/// One page of the note editor (bb-editor, bundled in CCPUI's resources) and
/// the documents open in it.
///
/// A page load is the expensive part — about a second and a half cold, and a
/// WebContent process of ~50MB — so each kind of surface gets exactly one,
/// loaded at launch and moved between the views that show it. The page keeps
/// an editor per document, so text, undo and scroll survive a tab switch.
///
/// The boundary with the rest of the app stays one markdown string per pad:
/// what the page saves goes back through ``UntouchedBlocks``, so a block the
/// user never edited keeps its stored bytes and the push hears only about
/// the blocks that changed.
@MainActor
@Observable
final class NoteEditorController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let notes = NoteEditorController(style: .notes)

    /// Where the caret of the shown document sits, for the format rail.
    struct Caret: Equatable {
        var documentId: String
        /// The caret line's vertical middle, in the web view's own points.
        var midY: CGFloat
        var headingLevel: Int
    }

    @ObservationIgnored let webView: NoteEditorWebView
    /// The shown document's caret while it is focused; nil otherwise.
    private(set) var caret: Caret?

    @ObservationIgnored private let style: NoteEditorStyle
    @ObservationIgnored private let pageURL: URL
    /// Loaded and configured: nothing is sent to the page before this.
    @ObservationIgnored private var isReady = false
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var documents: [String: Document] = [:]
    @ObservationIgnored private var shownDocumentId: String?

    /// What the app and the page each last knew of one document.
    private struct Document {
        /// The pad text the page loaded, and what the page saved it as then —
        /// the baseline ``UntouchedBlocks`` pairs blocks against.
        var source: String
        var loaded: String?
        /// The page's newest save, as markdown.
        var pageMarkdown: String?
        /// The pad text last handed to, or taken from, the app.
        var text: String
        var onText: (String) -> Void
    }

    init(style: NoteEditorStyle) {
        self.style = style
        let configuration = WKWebViewConfiguration()
        webView = NoteEditorWebView(frame: .zero, configuration: configuration)
        guard let url = Bundle.module.url(forResource: "editor", withExtension: "html", subdirectory: "NoteEditor")
        else { preconditionFailure("editor.html is missing from CCPUI's resources") }
        pageURL = url
        super.init()
        webView.navigationDelegate = self
        configuration.userContentController.add(WeakMessageHandler(self), name: "bbEditor")
        // Transparent, so the surface's own fill shows through.
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityLabel(style.accessibilityLabel)
        webView.appearance = style.appearance
        load()
    }

    private func load() {
        webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
    }

    /// Show `documentId` holding `text`, and hear its edits on `onText`.
    ///
    /// The first call for a document loads it. Later calls with the text the
    /// editor itself last reported change nothing; any other text came from
    /// outside — a pull, a restore — and replaces the document, unless the
    /// user has typed since, in which case their text wins and goes back
    /// through `onText` for the sync to reconcile.
    @discardableResult
    func show(documentId: String, text: String, onText: @escaping (String) -> Void) -> Task<Void, Never> {
        if var document = documents[documentId] {
            document.onText = onText
            documents[documentId] = document
            if text != document.text { replace(documentId: documentId, with: text) }
        } else {
            documents[documentId] = Document(source: text, text: text, onText: onText)
        }
        guard shownDocumentId != documentId || documents[documentId]?.loaded == nil else { return Task {} }
        shownDocumentId = documentId
        return Task {
            await ready()
            guard let loaded = try? await call("return bbEditor.open(id, markdown)",
                                               ["id": documentId, "markdown": text]) as? String
            else { return }
            if documents[documentId]?.loaded == nil { documents[documentId]?.loaded = loaded }
        }
    }

    /// Give the web view key focus with the caret in the shown document: at
    /// the end, or wherever it already was.
    func focusShown(atEnd: Bool) {
        guard let documentId = shownDocumentId else { return }
        webView.window?.makeFirstResponder(webView)
        Task {
            await ready()
            _ = try? await call("bbEditor.focus(id, atEnd ? 'end' : null)", ["id": documentId, "atEnd": atEnd])
        }
    }

    /// Give the web view key focus in `documentId`, with the caret at the
    /// text under `point` (in the web view's own coordinates), or at the end.
    @discardableResult
    func focus(documentId: String, at point: CGPoint?) -> Task<Void, Never> {
        webView.window?.makeFirstResponder(webView)
        return Task {
            await ready()
            let position: Any = point.map { ["x": $0.x, "y": $0.y] } ?? "end"
            _ = try? await call("bbEditor.focus(id, position)", ["id": documentId, "position": position])
        }
    }

    /// Close every document but `documentIds`: a deleted pad or sticky
    /// otherwise keeps its editor in the page for as long as the app runs.
    func closeDocuments(except documentIds: Set<String>) {
        for id in documents.keys where !documentIds.contains(id) {
            documents[id] = nil
            if shownDocumentId == id { shownDocumentId = nil }
            if caret?.documentId == id { caret = nil }
            Task {
                await ready()
                _ = try? await call("bbEditor.close(id)", ["id": id])
            }
        }
    }

    /// Takes the caret out of the page, so a snapshot draws none.
    func blur() async {
        await ready()
        _ = try? await call("bbEditor.blur()", [:])
    }

    /// The web view as it draws right now.
    func snapshot() async -> NSImage? {
        await ready()
        return try? await webView.takeSnapshot(configuration: nil)
    }

    /// Run one of the editor's own commands — `toggleBold`, `setHeading` —
    /// on the shown document, keeping the caret in it.
    func run(_ command: String, _ argument: [String: Any]? = nil, documentId: String) {
        webView.window?.makeFirstResponder(webView)
        Task {
            await ready()
            let script = argument == nil
                ? "bbEditor.command(id, name)"
                : "bbEditor.command(id, name, argument)"
            var arguments: [String: Any] = ["id": documentId, "name": command]
            if let argument { arguments["argument"] = argument }
            _ = try? await call(script, arguments)
        }
    }

    private func replace(documentId: String, with text: String) {
        guard let document = documents[documentId] else { return }
        documents[documentId]?.text = text
        Task {
            await ready()
            let expected: Any = document.pageMarkdown ?? document.loaded ?? NSNull()
            guard let result = try? await call(
                "return bbEditor.replace(id, markdown, expected ?? undefined)",
                ["id": documentId, "markdown": text, "expected": expected]) as? [String: Any],
                let markdown = result["markdown"] as? String
            else { return }
            if result["applied"] as? Bool == true {
                documents[documentId]?.source = text
                documents[documentId]?.loaded = markdown
                documents[documentId]?.pageMarkdown = markdown
            } else {
                receiveChange(documentId: documentId, markdown: markdown)
            }
        }
    }

    // MARK: - The page's messages

    nonisolated func userContentController(_ controller: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any] ?? [:]
        MainActor.assumeIsolated { receive(body) }
    }

    private func receive(_ body: [String: Any]) {
        let documentId = body["id"] as? String
        switch body["type"] as? String {
        case "ready":
            Task {
                _ = try? await call("bbEditor.configure(settings)", ["settings": style.pageSettings])
                isReady = true
                readyWaiters.forEach { $0.resume() }
                readyWaiters.removeAll()
            }
        case "change":
            guard let documentId, let markdown = body["markdown"] as? String else { return }
            receiveChange(documentId: documentId, markdown: markdown)
        case "selection":
            guard let documentId, body["isFocused"] as? Bool == true,
                  let midY = body["caretMidY"] as? Double
            else {
                if caret?.documentId == documentId { caret = nil }
                return
            }
            caret = Caret(documentId: documentId, midY: midY,
                          headingLevel: body["headingLevel"] as? Int ?? 0)
        case "blur":
            if caret?.documentId == documentId { caret = nil }
        case "openLink":
            guard let href = body["href"] as? String, let url = URL(string: href) else { return }
            NSWorkspace.shared.open(url)
        default:
            break
        }
    }

    private func receiveChange(documentId: String, markdown: String) {
        guard var document = documents[documentId] else { return }
        document.pageMarkdown = markdown
        let text = document.loaded.map {
            UntouchedBlocks.restore(in: markdown, loaded: $0, source: document.source)
        } ?? markdown
        document.text = text
        documents[documentId] = document
        document.onText(text)
    }

    // MARK: - Navigation

    /// The page is the only thing this web view ever shows: a dropped file
    /// or a followed link would navigate away from every open document.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy {
        navigationAction.request.url == pageURL ? .allow : .cancel
    }

    /// The system can end the page's process under memory pressure. Load it
    /// again and reopen the shown document from the app's text, which has
    /// every edit the page reported.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        caret = nil
        for (id, document) in documents {
            documents[id] = Document(source: document.text, text: document.text, onText: document.onText)
        }
        let shown = shownDocumentId
        shownDocumentId = nil
        load()
        if let shown, let document = documents[shown] {
            show(documentId: shown, text: document.text, onText: document.onText)
        }
    }

    // MARK: - Calling the page

    private func ready() async {
        guard !isReady else { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    private func call(_ script: String, _ arguments: [String: Any]) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
    }
}

/// The user content controller holds its handlers strongly, and a controller
/// that holds its web view would never be released through it.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// A web view that takes the click that also keys the panel, as a text view
/// does — otherwise the first click only focuses the window.
final class NoteEditorWebView: WKWebView {
    /// Hears the view give up key focus: a sticky's editor leaves the card
    /// when it does.
    var onResignFirstResponder: (() -> Void)?
    /// Takes files dropped on the editor. The page would otherwise get them,
    /// and a browser's answer to a dropped file is to open it. Unset, file
    /// drops go to the page and land nowhere.
    var onFileDrop: (([URL]) -> Bool)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender) == nil ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender) == nil ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let files = droppedFiles(sender), let onFileDrop else { return super.performDragOperation(sender) }
        return onFileDrop(files)
    }

    private func droppedFiles(_ sender: NSDraggingInfo) -> [URL]? {
        guard onFileDrop != nil,
              let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty
        else { return nil }
        return urls
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign { onResignFirstResponder?() }
        return didResign
    }
}
