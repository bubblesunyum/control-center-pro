// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit

/// The one note editor every sticky shares.
///
/// An editor page costs a WebContent process of about 50MB, and one per
/// sticky grows without bound. So there is exactly one: it moves into the
/// sticky being typed in, and every other sticky shows a snapshot of itself
/// drawn by that same page — the same pixels the live editor draws, so
/// clicking in never moves a line of text. Memory stays flat however many
/// stickies there are (ccp-9vpv.9).
///
/// While no sticky holds it, the editor waits in a window off every screen,
/// which is also where snapshots of stickies nobody is typing in get drawn.
@MainActor
@Observable
final class StickyEditorController {
    static let shared = StickyEditorController()

    /// The sticky the editor is in; every other one shows its snapshot.
    private(set) var focusedStickyID: UUID?
    private(set) var snapshots: [UUID: NSImage] = [:]

    @ObservationIgnored let page = NoteEditorController(style: .sticky)
    @ObservationIgnored private let parking = NSWindow(
        contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 400),
        styleMask: .borderless, backing: .buffered, defer: false)
    /// Where to put the caret once the editor has arrived in the sticky.
    @ObservationIgnored private var pendingCaret: (id: UUID, point: CGPoint?)?
    /// Stickies whose snapshot is out of date, drawn once the editor is free.
    @ObservationIgnored private var staleSnapshots: [UUID: (sticky: Sticky, size: CGSize)] = [:]
    /// One thing at a time: a snapshot and a move both need the editor.
    @ObservationIgnored private var queue: Task<Void, Never>?

    private init() {
        parking.isReleasedWhenClosed = false
        park()
        page.webView.onResignFirstResponder = { [weak self] in
            guard let self, focusedStickyID != nil else { return }
            enqueue { await self.leaveFocusedSticky() }
        }
    }

    /// Put the editor in `sticky` with the caret under `point` (in the
    /// sticky's editor coordinates), or at the end.
    func focus(_ sticky: Sticky, at point: CGPoint?) {
        enqueue { [self] in
            if focusedStickyID == sticky.id {
                await page.focus(documentId: Self.documentId(sticky.id), at: point).value
                return
            }
            await leaveFocusedSticky()
            await page.show(documentId: Self.documentId(sticky.id), text: sticky.text,
                            onText: Self.setText(for: sticky.id)).value
            pendingCaret = (sticky.id, point)
            focusedStickyID = sticky.id
        }
    }

    /// The live editor arrived in `host`, the focused sticky's card.
    func didMount(in host: NSView) {
        let webView = page.webView
        if webView.superview !== host {
            webView.removeFromSuperview()
            webView.frame = host.bounds
            webView.autoresizingMask = [.width, .height]
            host.addSubview(webView)
        }
        guard let caret = pendingCaret, caret.id == focusedStickyID else { return }
        pendingCaret = nil
        page.focus(documentId: Self.documentId(caret.id), at: caret.point)
    }

    /// Text that changed without the editor — a sync, the desk's own push.
    func textChanged(_ sticky: Sticky, size: CGSize) {
        if focusedStickyID == sticky.id {
            page.show(documentId: Self.documentId(sticky.id), text: sticky.text,
                      onText: Self.setText(for: sticky.id))
        } else {
            redraw(sticky, size: size)
        }
    }

    /// Draw `sticky`'s snapshot at `size` — now if the editor is free, or
    /// as soon as it is.
    func redraw(_ sticky: Sticky, size: CGSize) {
        staleSnapshots[sticky.id] = (sticky, size)
        guard focusedStickyID == nil else { return }
        enqueue { await self.drawStaleSnapshots() }
    }

    /// Let go of every sticky but `ids`, the ones still on the desk: their
    /// snapshots, and their editors in the page.
    func keep(only ids: Set<UUID>) {
        snapshots = snapshots.filter { ids.contains($0.key) }
        staleSnapshots = staleSnapshots.filter { ids.contains($0.key) }
        if let focused = focusedStickyID, !ids.contains(focused) {
            focusedStickyID = nil
            park()
        }
        page.closeDocuments(except: Set(ids.map(Self.documentId)))
    }

    // MARK: - Moving the editor

    private func leaveFocusedSticky() async {
        guard let id = focusedStickyID else { return }
        await page.blur()
        if let image = await page.snapshot() { snapshots[id] = image }
        focusedStickyID = nil
        park()
        await drawStaleSnapshots()
    }

    private func park() {
        guard page.webView.superview !== parking.contentView else { return }
        page.webView.removeFromSuperview()
        page.webView.autoresizingMask = []
        parking.contentView?.addSubview(page.webView)
    }

    private func drawStaleSnapshots() async {
        while focusedStickyID == nil, let (id, stale) = staleSnapshots.first {
            staleSnapshots[id] = nil
            page.webView.frame = CGRect(origin: .zero, size: stale.size)
            await page.show(documentId: Self.documentId(id), text: stale.sticky.text,
                            onText: Self.setText(for: id)).value
            if let image = await page.snapshot() { snapshots[id] = image }
        }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        queue = Task { [previous = queue] in
            await previous?.value
            await work()
        }
    }

    private static func documentId(_ id: UUID) -> String { "sticky-\(id.uuidString)" }

    private static func setText(for id: UUID) -> (String) -> Void {
        { StickyStore.shared.setText($0, for: id) }
    }
}
