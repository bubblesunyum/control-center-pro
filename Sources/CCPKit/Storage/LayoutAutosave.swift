// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Writes the layout a beat after it stops changing, and never on the main
/// thread.
///
/// Edit mode rearranges the layout continuously — a drag across two lanes is
/// dozens of mutations, each a complete arrangement worth saving — and
/// `JSONFileStore.save` is blocking file I/O. Saving on every one of them would
/// put a write inside a drag frame. So: the last layout wins, the write happens
/// once the user stops moving, and it happens off main.
///
/// `flush()` is the other half. A debounce that can be outrun by quitting is a
/// debounce that loses work, so the panel closing and the app terminating both
/// force the pending write out.
///
/// Every write goes through one serial queue, and that ordering is the whole
/// correctness argument: cancelling the timer cannot recall a write already on
/// its way, so a flush racing a write that is already going out would otherwise
/// let the older arrangement land last and quietly undo the newer one. First
/// scheduled, first written, and `flush()` waits for the queue to drain — which
/// is also why this is a queue rather than a task: the callers are
/// `applicationWillTerminate` and the panel closing, neither of which can await.
@MainActor
public final class LayoutAutosave {
    private let store: JSONFileStore<PanelLayout>
    private let delay: Duration
    private let writes = DispatchQueue(label: "com.controlcenterpro.layout-autosave")
    private var pending: Task<Void, Never>?
    private var unwritten: PanelLayout?

    public init(store: JSONFileStore<PanelLayout>, delay: Duration = .milliseconds(500)) {
        self.store = store
        self.delay = delay
    }

    public func schedule(_ layout: PanelLayout) {
        pending?.cancel()
        unwritten = layout

        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            write(layout)
            settled(layout)
        }
    }

    /// Write anything still waiting, and don't come back until everything
    /// already on its way has landed. Blocking on purpose: the caller is on
    /// its way out and there is nothing left to be responsive for.
    public func flush() {
        pending?.cancel()
        pending = nil

        if let layout = unwritten {
            unwritten = nil
            write(layout)
        }
        writes.sync {}
    }

    private func write(_ layout: PanelLayout) {
        writes.async { [store] in try? store.save(layout) }
    }

    private func settled(_ layout: PanelLayout) {
        guard unwritten == layout else { return }
        unwritten = nil
        pending = nil
    }
}
