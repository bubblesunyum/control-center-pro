// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit

/// Tracks the Notes caret's visible height for the format rail.
///
/// The engine reports caret rects only for link previews, and `firstRect`
/// answers zero on its TextKit-2 view — so the monitor observes selection and
/// scroll itself and measures through the shared `caretLineRect` geometry.
/// Object-scoped to the tracked view: one Notes pad, never the stickies.
///
/// Upstream is untouched; this watches the engine's text view from outside
/// it, like the return, delete, and caret monitors.
///
/// A plain class rather than a `@MainActor` one like the other monitors:
/// views own it, and views here are not actor-isolated. Every touch lands on
/// the main thread in practice — AppKit posts selection and scroll notes
/// there, and SwiftUI drives track/untrack there — which is also the only
/// thread `onUpdate` ever fires on.
final class RailCaretMonitor {
    private let center: NotificationCenter
    private let measure: (NSTextView) -> CGFloat?
    private var observers: [any NSObjectProtocol] = []
    private weak var textView: NSTextView?

    /// Fires with the caret line's midpoint in the editor scroll view's own
    /// coordinates — the space the rail's overlay shares — or nil when the
    /// rail should hide (unfocused, torn down).
    var onUpdate: ((CGFloat?) -> Void)?

    init(center: NotificationCenter = .default,
         measure: @escaping (NSTextView) -> CGFloat? = defaultRailMeasure) {
        self.center = center
        self.measure = measure
    }

    var isWatching: Bool { !observers.isEmpty }

    func track(_ textView: NSTextView?) {
        stopObserving()
        guard let textView else { return }
        self.textView = textView
        // Enabling these on the engine's clip view only posts notifications;
        // the engine tracks scroll its own way and never notices.
        if let clipView = textView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                                object: clipView, queue: nil) { [weak self] _ in
                self?.refresh()
            })
        }
        if let scrollView = textView.enclosingScrollView {
            scrollView.postsFrameChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification,
                                                object: scrollView, queue: nil) { [weak self] _ in
                self?.refresh()
            })
        }
        observers.append(center.addObserver(forName: NSTextView.didChangeSelectionNotification,
                                            object: textView, queue: nil) { [weak self] _ in
            self?.refresh()
        })
        refresh()
    }

    func untrack() {
        stopObserving()
        onUpdate?(nil)
    }

    private func stopObserving() {
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        textView = nil
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    private func refresh() {
        onUpdate?(textView.flatMap(measure))
    }
}

/// The caret line's midpoint in its scroll view's coordinates, or nil when
/// the rail should hide: a field editor, an uneditable pad, anything but the
/// focused editor, or a view not laid out in a scroll view yet. Free function
/// rather than a static member so the initializer can name it as a default
/// argument (`Self` is not allowed there).
private func defaultRailMeasure(_ textView: NSTextView) -> CGFloat? {
    guard !textView.isFieldEditor,
          textView.isEditable,
          let window = textView.window,
          window.firstResponder === textView,
          let scrollView = textView.enclosingScrollView,
          let line = caretLineRect(for: textView, at: textView.selectedRange().location),
          line.height > 0
    else { return nil }
    // Already flipped throughout: the document midpoint minus the scrolled
    // origin lands in the scroll view's own space, which the rail's overlay
    // shares.
    return line.midY - scrollView.contentView.bounds.origin.y
}
