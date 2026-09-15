// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import SwiftUI

/// A note, edited in the editor page `controller` holds.
///
/// Every `NoteEditor` on one controller shares its single web view, which
/// moves into whichever editor mounted last — right for Notes, which shows
/// one pad at a time.
struct NoteEditor: View {
    @Binding var text: String
    /// Which pad this is. The page keeps text, undo and scroll per document.
    let documentId: String
    var controller: NoteEditorController = .notes

    var body: some View {
        NoteEditorRepresentable(controller: controller)
            .onChange(of: documentId, initial: true) { show() }
            .onChange(of: text) { show() }
    }

    private func show() {
        controller.show(documentId: documentId, text: text, onText: { [$text] in $text.wrappedValue = $0 })
    }
}

private struct NoteEditorRepresentable: NSViewRepresentable {
    let controller: NoteEditorController

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        adopt(into: host)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        adopt(into: host)
    }

    private func adopt(into host: NSView) {
        let webView = controller.webView
        guard webView.superview !== host else { return }
        webView.removeFromSuperview()
        webView.frame = host.bounds
        webView.autoresizingMask = [.width, .height]
        host.addSubview(webView)
    }
}
