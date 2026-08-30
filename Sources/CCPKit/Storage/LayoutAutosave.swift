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
/// force the pending write out synchronously.
@MainActor
public final class LayoutAutosave {
    private let store: JSONFileStore<PanelLayout>
    private let delay: Duration
    private var pending: Task<Void, Never>?
    private var unwritten: PanelLayout?

    public init(store: JSONFileStore<PanelLayout>, delay: Duration = .milliseconds(500)) {
        self.store = store
        self.delay = delay
    }

    public func schedule(_ layout: PanelLayout) {
        pending?.cancel()
        unwritten = layout

        pending = Task { [store, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await Task.detached { try? store.save(layout) }.value
            self.settled(layout)
        }
    }

    /// Write anything still waiting, now. Blocking on purpose: the caller is
    /// on its way out and there is nothing left to be responsive for.
    public func flush() {
        pending?.cancel()
        pending = nil
        guard let layout = unwritten else { return }
        unwritten = nil
        try? store.save(layout)
    }

    private func settled(_ layout: PanelLayout) {
        guard unwritten == layout else { return }
        unwritten = nil
        pending = nil
    }
}
