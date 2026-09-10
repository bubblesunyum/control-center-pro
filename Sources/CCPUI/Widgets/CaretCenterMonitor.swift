// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit

/// Typing or moving the caret while its line is off-screen brings the line to
/// the middle of the note view, instead of AppKit's minimal edge reveal
/// (ccp-sotw).
///
/// AppKit posts `textDidChange`/`didChangeSelection` BEFORE it auto-scrolls
/// (probed: selection, text, then the clip view's bounds change), so the
/// event-time check still sees the caret where the user left it. The scroll
/// itself waits a tick: the engine restyles after the edit and AppKit
/// edge-scrolls first, so centering lands on settled layout and simply
/// replaces the edge position. That is why a pending flag — not current
/// visibility — drives the flush: by flush time AppKit has already made the
/// caret "visible" at the edge, and a visibility check there would no-op and
/// lose. The flush still re-measures fresh and leaves a caret that landed
/// mid-view alone; only one stranded within a line of the edge gets rescued
/// (that is AppKit's reveal, not a destination — a same-tick programmatic
/// move further in is never yanked).
///
/// Only the focused editor counts (`firstResponder`, read inside the default
/// measure): a background pull rebuilding text must never scroll the view out
/// from under a reader. Deliberately NOT `isKeyWindow`: the panel is a
/// non-activating panel and is never key, so that check would disable the
/// feature outright — and it is also unneeded, since Notes and the stickies
/// share the panel's single window, where the designated first responder is
/// unambiguous. Selections count as the user's drag and are left alone —
/// collapsed carets only.
///
/// Upstream is untouched; this watches the engine's text view from outside
/// it, like the return, delete, and hard-break monitors. One observer covers
/// the Notes card and every sticky: all are plain editable text views, never
/// field editors.
@MainActor
final class CaretCenterMonitor {
    /// Everything the centering decision needs, in document coordinates.
    struct Snapshot {
        let caretMinY: CGFloat
        let caretMaxY: CGFloat
        let visibleMinY: CGFloat
        let visibleHeight: CGFloat
        let contentHeight: CGFloat
    }

    private let center: NotificationCenter
    private let schedule: (@escaping () -> Void) -> Void
    private let measure: (NSTextView) -> Snapshot?
    private let scroll: (NSTextView, CGFloat) -> Void
    private var observers: [any NSObjectProtocol] = []
    private var pending = NSHashTable<NSTextView>.weakObjects()
    private var isFlushScheduled = false

    init(center: NotificationCenter = .default,
         schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         measure: @escaping (NSTextView) -> Snapshot? = defaultCaretMeasure,
         scroll: @escaping (NSTextView, CGFloat) -> Void = defaultCaretScroll) {
        self.center = center
        self.schedule = schedule
        self.measure = measure
        self.scroll = scroll
    }

    var isWatching: Bool { !observers.isEmpty }

    func start() {
        guard observers.isEmpty else { return }
        observers = [
            center.addObserver(forName: NSText.didChangeNotification,
                               object: nil, queue: nil) { [weak self] note in
                MainActor.assumeIsolated { self?.handle(note) }
            },
            center.addObserver(forName: NSTextView.didChangeSelectionNotification,
                               object: nil, queue: nil) { [weak self] note in
                MainActor.assumeIsolated { self?.handle(note) }
            },
        ]
    }

    func stop() {
        for observer in observers { center.removeObserver(observer) }
        observers = []
        pending.removeAllObjects()
        isFlushScheduled = false
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    private func handle(_ note: Notification) {
        guard let textView = note.object as? NSTextView,
              // The pad's own views, never a field editor: the same scoping
              // the return and delete monitors use.
              !textView.isFieldEditor,
              textView.isEditable,
              !textView.hasMarkedText(),
              // A selection drag is the user's; only a collapsed caret gets
              // centered.
              textView.selectedRange().length == 0,
              let snapshot = measure(textView),
              // Unforced: nil means visible (or nothing to scroll), and only
              // an off-screen caret arms the flush.
              Self.targetOriginY(for: snapshot, force: false) != nil
        else { return }
        pending.add(textView)
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        schedule { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        isFlushScheduled = false
        let views = pending.allObjects
        pending.removeAllObjects()
        for textView in views {
            // Settle estimated heights above the caret (a table image stands
            // in as one text line, ~250pt short) before trusting the verdict
            // or aiming off it. Once per arming, never per keystroke — the
            // event-time check stays O(line).
            settleCaretLayout(for: textView)
            guard !textView.isFieldEditor,
                  textView.isEditable,
                  !textView.hasMarkedText(),
                  textView.selectedRange().length == 0,
                  let snapshot = measure(textView),
                  // Forced: rescues the caret AppKit just edge-revealed, but
                  // still leaves one that landed mid-view alone.
                  let target = Self.targetOriginY(for: snapshot, force: true)
            else { continue }
            scroll(textView, target)
        }
    }

    /// Where the viewport's origin belongs so the caret line sits mid-view,
    /// or nil when the view should stay put. Pure so the geometry is provable
    /// without a window.
    static func targetOriginY(for snapshot: Snapshot, force: Bool) -> CGFloat? {
        let caretMid = (snapshot.caretMinY + snapshot.caretMaxY) / 2
        let visibleMax = snapshot.visibleMinY + snapshot.visibleHeight
        let offScreen = snapshot.caretMaxY <= snapshot.visibleMinY
            || snapshot.caretMinY >= visibleMax
        let maxOrigin = max(snapshot.contentHeight - snapshot.visibleHeight, 0)
        guard maxOrigin > 0 else { return nil }
        let centered = min(max(caretMid - snapshot.visibleHeight / 2, 0), maxOrigin)
        if offScreen { return centered }
        guard force else { return nil }
        // The flush runs after AppKit's edge reveal: a caret stranded within
        // a line of the edge is that reveal, and gets centered. One sitting
        // further in arrived there some other way and stays.
        let margin = max(snapshot.caretMaxY - snapshot.caretMinY, 2)
        let nearTop = snapshot.caretMinY - snapshot.visibleMinY < margin
        let nearBottom = visibleMax - snapshot.caretMaxY < margin
        guard nearTop || nearBottom else { return nil }
        return centered
    }

}

/// The caret line and viewport in document coordinates, or nil when this
/// view is not the focused editor and must be left alone. Free functions
/// rather than static members so the initializer can name them as default
/// arguments (`Self` is not allowed there).
private func defaultCaretMeasure(_ textView: NSTextView) -> CaretCenterMonitor.Snapshot? {
    guard let window = textView.window,
          window.firstResponder === textView,
          let scrollView = textView.enclosingScrollView,
          let document = scrollView.documentView
    else { return nil }
    let caret = textView.selectedRange()
    guard caret.length == 0 else { return nil }
    // Deliberately NOT `firstRect(forCharacterRange:)`: it answers a zero
    // rect on this view (probed 2026-09-10), which is also why AppKit's own
    // edge reveal never fires here. Fragment enumeration is what the engine
    // itself trusts for caret geometry.
    guard let line = caretLineRect(for: textView) else { return nil }
    // Already document coordinates: the lift inside `caretLineRect`
    // accounts for the container's inset, and both views are flipped, so no
    // axis work remains.
    guard line.height > 0 else { return nil }
    let visible = scrollView.contentView.bounds
    return CaretCenterMonitor.Snapshot(caretMinY: line.minY,
                                       caretMaxY: line.maxY,
                                       visibleMinY: visible.minY,
                                       visibleHeight: visible.height,
                                       contentHeight: document.frame.height)
}

/// The caret's line in document coordinates: its text segment where there is
/// one, else its layout fragment. The true location is tried first, then one
/// char back — a caret at the document end has no fragment of its own (the
/// engine steps back for the same reason).
private func caretLineRect(for textView: NSTextView) -> CGRect? {
    // The engine's view is TextKit 2, where `layoutManager` is nil.
    guard let layout = textView.textLayoutManager,
          let content = layout.textContentManager
    else { return nil }
    let caret = textView.selectedRange()
    guard caret.length == 0 else { return nil }
    let start = content.documentRange.location
    var locations: [NSTextLocation] = []
    if let at = content.location(start, offsetBy: caret.location) { locations.append(at) }
    if caret.location > 0, let back = content.location(start, offsetBy: caret.location - 1) {
        locations.append(back)
    }
    for location in locations {
        let range = NSTextRange(location: location)
        layout.ensureLayout(for: range)
        var lineRect: CGRect?
        layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, rect, _, _ in
            if rect.height > 0 { lineRect = rect }
            return false
        }
        if let lineRect { return lift(lineRect, for: textView) }
    }
    for location in locations {
        var fragmentRect: CGRect?
        layout.enumerateTextLayoutFragments(from: location,
                                            options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            fragmentRect = fragment.layoutFragmentFrame
            return false
        }
        if let fragmentRect { return lift(fragmentRect, for: textView) }
    }
    return nil
}

/// Segment and fragment frames are container-local; the container sits one
/// `textContainerOrigin` inside its (flipped, like the document) text view,
/// so the lift lands in document coordinates.
private func lift(_ rect: CGRect, for textView: NSTextView) -> CGRect {
    rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
}

/// Lay out everything above the caret so estimated heights (a table image
/// stands in as one text line, ~250pt short) can't skew the flush's verdict
/// or target. The event-time check deliberately skips this: a skewed verdict
/// there self-heals on the next keystroke, while a doc-start layout per
/// keystroke would not be cheap.
private func settleCaretLayout(for textView: NSTextView) {
    guard let layout = textView.textLayoutManager,
          let content = layout.textContentManager
    else { return }
    let caret = textView.selectedRange()
    guard caret.length == 0,
          let at = content.location(content.documentRange.location, offsetBy: caret.location),
          let whole = NSTextRange(location: content.documentRange.location, end: at)
    else { return }
    layout.ensureLayout(for: whole)
}

/// A smooth vertical glide to `originY`, keeping the horizontal position.
/// Instant under Reduce Motion.
private func defaultCaretScroll(_ textView: NSTextView, _ originY: CGFloat) {
    guard let scrollView = textView.enclosingScrollView else { return }
    let clip = scrollView.contentView
    let target = NSPoint(x: clip.bounds.origin.x, y: originY)
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        clip.setBoundsOrigin(target)
        scrollView.reflectScrolledClipView(clip)
        return
    }
    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.25
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        clip.animator().setBoundsOrigin(target)
        scrollView.reflectScrolledClipView(clip)
    }
}
