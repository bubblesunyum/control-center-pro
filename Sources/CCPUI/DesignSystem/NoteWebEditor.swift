// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import SwiftUI
import WebKit

/// Spike (ccp-5hpw): the note as Tiptap in a WKWebView, behind the
/// `spikeTiptapNotes` default.
///
/// It shows the selected pad and takes typing, but never writes back — the
/// spike measures the panel with real notes in it, it does not own them.
/// Timings land in `/tmp/ccp-tiptap-spike.log`. With `spikeTiptapScratch`
/// also on, the page starts empty instead of showing the pad, and mirrors
/// what is typed to `/tmp/ccp-tiptap-spike.md` so a driven test can read it.
struct NoteWebEditor: View {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "spikeTiptapNotes") }
    static var isScratch: Bool { UserDefaults.standard.bool(forKey: "spikeTiptapScratch") }

    let markdown: String
    let documentId: String
    @Environment(\.panelFocus) private var panelFocus

    var body: some View {
        NoteWebEditorRepresentable(controller: .shared, markdown: markdown, documentId: documentId)
            .onAppear { panelFocus?.notesWebView = NoteWebEditorController.shared.webView }
    }
}

private struct NoteWebEditorRepresentable: NSViewRepresentable {
    let controller: NoteWebEditorController
    let markdown: String
    let documentId: String

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        adopt(into: host)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        adopt(into: host)
        controller.show(padText: markdown, documentId: documentId)
    }

    /// One web view outlives every mount: a page load is the expensive part,
    /// so it happens once at launch and the view is only ever reparented.
    private func adopt(into host: NSView) {
        let webView = controller.webView
        guard webView.superview !== host else { return }
        webView.removeFromSuperview()
        webView.frame = host.bounds
        webView.autoresizingMask = [.width, .height]
        host.addSubview(webView)
    }
}

/// A web view that takes the click that also keys the panel, like the
/// native editor does — otherwise the first click only focuses the window.
final class NoteWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NoteWebEditorController: NSObject, WKScriptMessageHandler {
    static let shared = NoteWebEditorController()

    let webView: NoteWebView
    private let createdAt = ContinuousClock.now
    private var isReady = false
    private var shownDocumentId: String?
    private var shownPadText: String?
    /// Typed into since the last load: a pad arriving late (or a pull) may
    /// replace an untouched page, never one holding typing.
    private var isEdited = false
    private var pending: (text: String, documentId: String)?

    override init() {
        let configuration = WKWebViewConfiguration()
        webView = NoteWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "ccp")
        // Transparent, so the well's own fill shows through.
        webView.setValue(false, forKey: "drawsBackground")
        guard let url = Bundle.module.url(forResource: "editor", withExtension: "html",
                                          subdirectory: "NoteWebEditor")
        else {
            Self.log("editor.html missing from the CCPUI bundle")
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    /// Load a pad into the page when the selection moves to it. The same pad
    /// is never reloaded: the page holds the typing, and the pad text here is
    /// the unedited original.
    func show(padText: String, documentId: String) {
        let padText = NoteWebEditor.isScratch ? "" : padText
        guard documentId != shownDocumentId || (!isEdited && padText != shownPadText) else { return }
        guard isReady else {
            pending = (padText, documentId)
            return
        }
        shownDocumentId = documentId
        shownPadText = padText
        isEdited = false
        let markdown = Self.markdown(fromPad: padText)
        let start = ContinuousClock.now
        evaluate("ccpEditor.setMarkdown(\(Self.jsonString(markdown)))") { result in
            Self.log("setMarkdown \(markdown.utf8.count)B: page \(Self.ms(result)) ms, round trip \(Self.ms(since: start)) ms")
        }
    }

    /// How long from `start` until the page paints its next frame — what a
    /// panel open actually waits on before the note is live.
    func measureFirstFrame(since start: ContinuousClock.Instant, label: String) {
        Task {
            _ = try? await webView.callAsyncJavaScript(
                "await new Promise(r => requestAnimationFrame(() => r())); return 0",
                contentWorld: .page)
            Self.log("\(label): next frame \(Self.ms(since: start)) ms")
        }
    }

    func focusEnd() {
        evaluate("ccpEditor.focusEnd()")
    }

    nonisolated func userContentController(_ controller: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { receive(message.body as? [String: Any] ?? [:]) }
    }

    private func receive(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "ready":
            isReady = true
            Self.log("cold load: ready \(Self.ms(since: createdAt)) ms after init (page \(Self.ms(body["sinceNavigationMs"])) ms)")
            let insetX = Space.three + Space.one + Space.quarter
            let insetY = Space.three + Space.quarter
            evaluate("ccpEditor.configure({insetX: \(insetX), insetY: \(insetY), fontSize: \(MarkdownNoteEditor.fontSize)})")
            if let pending {
                self.pending = nil
                show(padText: pending.text, documentId: pending.documentId)
            }
        case "change":
            // Length only: the log is for timings, never note contents.
            isEdited = true
            let markdown = body["markdown"] as? String ?? ""
            Self.log("change: \(markdown.utf8.count)B markdown")
            if NoteWebEditor.isScratch {
                try? markdown.write(toFile: "/tmp/ccp-tiptap-spike.md", atomically: true, encoding: .utf8)
            }
        default:
            break
        }
    }

    private func evaluate(_ script: String, completion: ((Any?) -> Void)? = nil) {
        webView.evaluateJavaScript(script) { result, error in
            if let error { Self.log("js error: \(error.localizedDescription)") }
            completion?(result)
        }
    }

    /// The pad stores a block boundary as two trailing spaces before the
    /// newline; plain markdown spells it as a blank line.
    static func markdown(fromPad text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let trimmed = line.reversed().drop(while: { $0 == " " })
            let isBoundary = line.count - trimmed.count >= 2 && trimmed.contains { !$0.isWhitespace }
            return isBoundary ? String(trimmed.reversed()) + "\n" : String(line)
        }.joined(separator: "\n")
    }

    private static func jsonString(_ string: String) -> String {
        (try? JSONEncoder().encode(string)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private static func ms(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        return String(format: "%.1f", Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15)
    }

    private static func ms(_ value: Any?) -> String {
        String(format: "%.1f", (value as? Double) ?? .nan)
    }

    private static let logURL = URL(fileURLWithPath: "/tmp/ccp-tiptap-spike.log")

    static func log(_ line: String) {
        let stamped = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}
