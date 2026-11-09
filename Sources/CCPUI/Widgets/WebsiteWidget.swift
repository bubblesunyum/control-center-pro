// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import SwiftUI
import WebKit

/// A live website in a card.
///
/// The view resolves its site from `WebsiteStore` via the card's
/// `currentWidgetID` — dynamic `website-xxx` instances share this static
/// descriptor for sizing — and draws it in a pooled `WKWebView` that survives
/// panel opens, so the DOM (and a half-read page) survives them too. A reload
/// after an hour stale crossfades from a snapshot of the old page.
@MainActor
public final class WebsiteWidget: CCPWidget {
    public static let descriptor = WidgetDescriptor(
        id: "website",
        title: "Website",
        symbolName: "globe",
        size: .tall
    )

    public init() {}

    public func makeView() -> some View {
        WebsiteContent()
    }

    public func activate() {}

    @MainActor public static func discard(_ id: WidgetID) { WebsiteViewPool.shared.forget(id) }

    public func deactivate() {
        // The pool keeps its views warm on purpose: a pooled page costs its
        // process, not CPU, and rebuilding would drop the DOM.
    }
}

// MARK: - View pool

/// One `WKWebView` per site, kept alive across panel opens.
///
/// The pool owns the only strong references. `makeNSView` returns the pooled
/// view rather than building one, so a remount reattaches the same instance
/// instead of coming back blank. Each web view is its own content process —
/// one per site is accepted, and is why a removed site is forgotten outright.
@MainActor
private final class WebsiteViewPool {
    static let shared = WebsiteViewPool()

    private var views: [String: WKWebView] = [:]
    private var loadedEntryURLs: [String: String] = [:]

    private func entryAddress(for id: WidgetID) -> URL? {
        guard let raw = WebsiteStore.shared.entry(for: id)?.url,
            let url = URL(string: raw), url.host != nil
        else { return nil }
        return url
    }

    /// The site's view, created once. A fresh view loads the entry URL so a
    /// card never sits on a blank page; an existing one is returned untouched.
    func view(for id: WidgetID) -> WKWebView {
        if let existing = views[id.rawValue] { return existing }
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        views[id.rawValue] = webView
        if let url = entryAddress(for: id) {
            webView.load(URLRequest(url: url))
            loadedEntryURLs[id.rawValue] = url.absoluteString
        }
        return webView
    }

    /// The last entry URL this pool loaded for the site — entry changes only,
    /// never in-page navigation, which the pool must not undo.
    func loadedURLString(for id: WidgetID) -> String? {
        loadedEntryURLs[id.rawValue]
    }

    func load(_ id: WidgetID, url: URL) {
        view(for: id).load(URLRequest(url: url))
        loadedEntryURLs[id.rawValue] = url.absoluteString
    }

    /// Loads the entry URL when the view has never loaded anything. No
    /// transition: this is the first paint, not a reload.
    func loadIfNeeded(_ id: WidgetID) {
        let webView = view(for: id)
        guard webView.url == nil, let url = entryAddress(for: id) else { return }
        load(id, url: url)
    }

    /// Reloads the site's view only when one already exists. Never creates a
    /// view: a reload must not conjure a web view for a card that was never
    /// opened. Returns false when there is nothing to reload.
    func reloadExisting(_ id: WidgetID) -> Bool {
        guard let webView = views[id.rawValue] else { return false }
        webView.reload()
        return true
    }

    func snapshot(of id: WidgetID) async -> NSImage? {
        guard let webView = views[id.rawValue] else { return nil }
        return try? await webView.takeSnapshot(configuration: WKSnapshotConfiguration())
    }

    /// Drops the site's view outright. A removed widget that kept its process
    /// would be the leak the lifecycle exists to prevent.
    func forget(_ id: WidgetID) {
        views[id.rawValue]?.stopLoading()
        views[id.rawValue]?.navigationDelegate = nil
        views[id.rawValue] = nil
        loadedEntryURLs[id.rawValue] = nil
    }
}

// MARK: - Representable

/// The pooled web view, reattached on every mount. Identity stays with the
/// pool: the same `WidgetID` always yields the same `WKWebView`, so SwiftUI
/// never rebuilds (and blanks) the page underneath us.
private struct WebsiteWebView: NSViewRepresentable {
    let id: WidgetID
    let url: URL?
    let finishedCount: Binding<Int>
    let failedCount: Binding<Int>

    func makeCoordinator() -> Coordinator {
        Coordinator(finishedCount: finishedCount, failedCount: failedCount)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WebsiteViewPool.shared.view(for: id)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.finishedCount = finishedCount
        context.coordinator.failedCount = failedCount
        if webView.navigationDelegate !== context.coordinator {
            webView.navigationDelegate = context.coordinator
        }
        if let url, WebsiteViewPool.shared.loadedURLString(for: id) != url.absoluteString {
            WebsiteViewPool.shared.load(id, url: url)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var finishedCount: Binding<Int>
        var failedCount: Binding<Int>

        init(finishedCount: Binding<Int>, failedCount: Binding<Int>) {
            self.finishedCount = finishedCount
            self.failedCount = failedCount
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Main thread by WebKit contract; the write crosses to the view
            // through the binding, and the content decides whether a reload
            // was actually in flight.
            Task { @MainActor in
                finishedCount.wrappedValue += 1
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                failedCount.wrappedValue += 1
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                failedCount.wrappedValue += 1
            }
        }
    }
}

// MARK: - Content

private enum WebsiteReloadStyle {
    /// The whole card dims to this while a reload is in flight.
    static let dimmedOpacity = 0.81
    /// The outgoing page sinks to this under its own snapshot while the fresh
    /// one loads, then both crossfade back together.
    static let webDimmedOpacity = 0.3
    /// Screenshot out, web view in, in one transaction.
    static let crossfadeDuration = 0.54
}

private struct WebsiteContent: View {
    @State private var store = WebsiteStore.shared
    @Environment(\.panelArrangement) private var arrangement
    @Environment(\.currentWidgetID) private var currentWidgetID

    @State private var snapshot: NSImage?
    @State private var isReloading = false
    @State private var reloadOpacity = 1.0
    @State private var showURLSheet = false
    @State private var draftURL = ""
    @State private var finishedCount = 0
    @State private var failedCount = 0
    /// A URL-change load (not a reload) waiting for its finish to stamp the hour.
    @State private var awaitingFreshLoad = false
    @State private var reloadTask: Task<Void, Never>?

    private var entry: WebsiteEntry? {
        guard let id = currentWidgetID else { return nil }
        return store.entry(for: id)
    }

    private var currentURL: URL? {
        guard let raw = entry?.url, let url = URL(string: raw), url.host != nil else { return nil }
        return url
    }

    private var host: String? {
        currentURL?.host
    }

    /// The header reads the site's host; sizing stays `.tall` regardless.
    private var headerDescriptor: WidgetDescriptor {
        WidgetDescriptor(
            id: WebsiteWidget.descriptor.id,
            title: host ?? "Website",
            symbolName: "globe",
            size: .tall
        )
    }

    private var isOriginal: Bool {
        guard let entry else { return true }
        return entry.url == entry.originalURL
    }

    var body: some View {
        WidgetCard(headerDescriptor) {
            ZStack {
                if let id = currentWidgetID {
                    WebsiteWebView(id: id, url: currentURL, finishedCount: $finishedCount, failedCount: $failedCount)
                        .opacity(reloadOpacity)
                        .disabled(isReloading)
                } else {
                    Text("Website")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let snapshot {
                    Image(nsImage: snapshot)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: WidgetSize.tall.height)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .opacity(isReloading ? WebsiteReloadStyle.dimmedOpacity : 1)
        .contextMenu {
            Button("Reload") { runReloadSequence() }
                .accessibilityLabel("Reload website")
            Button("Change URL…") {
                draftURL = entry?.url ?? ""
                showURLSheet = true
            }
            .accessibilityLabel("Change website URL")
            Button("Reset to Original URL") { resetToOriginal() }
                .disabled(isOriginal)
                .accessibilityLabel("Reset to original URL")
            Divider()
            Button("Remove", role: .destructive) { removeSite() }
                .accessibilityLabel("Remove website")
        }
        .sheet(isPresented: $showURLSheet) {
            urlSheet
        }
        .accessibilityLabel(host.map { "Website: \($0)" } ?? "Website")
        .onAppear {
            guard let id = currentWidgetID else { return }
            if store.shouldReload(id, at: Date()) {
                runReloadSequence()
            } else {
                WebsiteViewPool.shared.loadIfNeeded(id)
            }
        }
        .onDisappear {
            reloadTask?.cancel()
        }
        .onChange(of: finishedCount) { _, _ in
            finishReload()
            if awaitingFreshLoad, let id = currentWidgetID {
                awaitingFreshLoad = false
                store.markReloaded(id, at: Date())
            }
        }
        .onChange(of: failedCount) { _, _ in
            failReload()
            if !isReloading { awaitingFreshLoad = false }
        }
    }

    /// Screenshot the stale page, dim the card, and reload underneath. The
    /// snapshot covers the white flash; `finishReload` crossfades it away.
    private func runReloadSequence() {
        guard let id = currentWidgetID, !isReloading else { return }
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            snapshot = await WebsiteViewPool.shared.snapshot(of: id)
            guard !Task.isCancelled, store.entry(for: id) != nil else {
                snapshot = nil
                return
            }
            guard WebsiteViewPool.shared.reloadExisting(id) else {
                snapshot = nil
                WebsiteViewPool.shared.loadIfNeeded(id)
                return
            }
            isReloading = true
            reloadOpacity = WebsiteReloadStyle.webDimmedOpacity
        }
    }

    /// The fresh page committed: fade the snapshot out and the web view in
    /// together, and stamp the reload so the hour starts now. Navigations
    /// that are not a reload (in-page links, the first paint) find
    /// `isReloading` false and do nothing.
    private func finishReload() {
        guard isReloading, let id = currentWidgetID else { return }
        reloadTask = nil
        withAnimation(.easeInOut(duration: WebsiteReloadStyle.crossfadeDuration)) {
            snapshot = nil
            reloadOpacity = 1
            isReloading = false
        }
        store.markReloaded(id, at: Date())
    }

    /// A reload that failed: clear the snapshot and undim without stamping,
    /// so the site stays eligible for a retry.
    private func failReload() {
        guard isReloading else { return }
        reloadTask = nil
        withAnimation(.easeInOut(duration: WebsiteReloadStyle.crossfadeDuration)) {
            snapshot = nil
            reloadOpacity = 1
        }
        isReloading = false
    }

    private func resetToOriginal() {
        guard let id = currentWidgetID else { return }
        takeOverFromReload()
        store.resetToOriginal(id)
        if let raw = store.entry(for: id)?.url,
            let url = URL(string: raw), url.host != nil
        {
            WebsiteViewPool.shared.load(id, url: url)
            awaitingFreshLoad = true
        }
    }

    private func removeSite() {
        reloadTask?.cancel()
        guard let id = currentWidgetID else { return }
        arrangement?.remove(id)
        WebsiteViewPool.shared.forget(id)
        store.remove(id)
    }

    private static func normalizedAddress(_ raw: String) -> String {
        WebsiteStore.normalizedURL(raw)
    }

    private var urlSheet: some View {
        VStack(alignment: .leading, spacing: Space.two) {
            Text("Website address")
                .font(.headline)
            TextField("Address", text: $draftURL)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Website address")
                .onSubmit(saveURL)
            HStack(spacing: Space.one) {
                Spacer()
                Button("Cancel") { showURLSheet = false }
                    .accessibilityLabel("Cancel changing URL")
                Button("Save") { saveURL() }
                    .accessibilityLabel("Save website URL")
                    .disabled(!isDraftValid)
            }
        }
        .padding(Space.two)
    }

    private var isDraftValid: Bool {
        let normalized = Self.normalizedAddress(draftURL)
        guard let url = URL(string: normalized), let host = url.host, !host.isEmpty else {
            return false
        }
        return true
    }

    private func saveURL() {
        guard let id = currentWidgetID, isDraftValid else { return }
        let normalized = Self.normalizedAddress(draftURL)
        guard let url = URL(string: normalized) else { return }
        takeOverFromReload()
        store.updateURL(id, to: normalized)
        WebsiteViewPool.shared.load(id, url: url)
        awaitingFreshLoad = true
        showURLSheet = false
    }

    /// A URL change takes over from any reload in flight: the old navigation
    /// is cancelled and its cover cleared, so the new load paints uncovered
    /// and its own finish stamps the hour. Without this the cancelled reload
    /// reports failure and yanks the cover mid-load, and the new page's
    /// finish finds nothing to stamp.
    private func takeOverFromReload() {
        reloadTask?.cancel()
        reloadTask = nil
        snapshot = nil
        reloadOpacity = 1
        isReloading = false
    }
}
