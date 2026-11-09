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
        let webView = WKWebView(frame: .zero, configuration: WebsiteConfiguration.makeConfiguration())
        views[id.rawValue] = webView
        if let url = entryAddress(for: id) {
            webView.load(URLRequest(url: url))
            loadedEntryURLs[id.rawValue] = url.absoluteString
        }
        return webView
    }

    /// The site's view without creating one. Controls must not conjure a web
    /// view (and its process) for a card that was never opened.
    func existingView(for id: WidgetID) -> WKWebView? {
        views[id.rawValue]
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
        views[id.rawValue]?.uiDelegate = nil
        views[id.rawValue] = nil
        loadedEntryURLs[id.rawValue] = nil
    }
}

// MARK: - Representable

/// A transient login popup, held in state so a sheet can present it. The view
/// itself is transient — pool identity stays the single rule for card views —
/// but it shares the pool's configuration, so the login session survives.
private struct LoginPopup: Identifiable {
    let id = UUID()
    let view: WKWebView
}

/// The pooled web view, reattached on every mount. Identity stays with the
/// pool: the same `WidgetID` always yields the same `WKWebView`, so SwiftUI
/// never rebuilds (and blanks) the page underneath us.
private struct WebsiteWebView: NSViewRepresentable {
    let id: WidgetID
    let url: URL?
    let finishedCount: Binding<Int>
    let failedCount: Binding<Int>
    let popupHost: Binding<LoginPopup?>

    func makeCoordinator() -> Coordinator {
        Coordinator(
            id: id,
            finishedCount: finishedCount,
            failedCount: failedCount,
            popupHost: popupHost
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WebsiteViewPool.shared.view(for: id)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.finishedCount = finishedCount
        context.coordinator.failedCount = failedCount
        context.coordinator.popupHost = popupHost
        if webView.navigationDelegate !== context.coordinator {
            webView.navigationDelegate = context.coordinator
        }
        if webView.uiDelegate !== context.coordinator {
            webView.uiDelegate = context.coordinator
        }
        if let url, WebsiteViewPool.shared.loadedURLString(for: id) != url.absoluteString {
            WebsiteViewPool.shared.load(id, url: url)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let id: WidgetID
        var finishedCount: Binding<Int>
        var failedCount: Binding<Int>
        var popupHost: Binding<LoginPopup?>

        init(
            id: WidgetID,
            finishedCount: Binding<Int>,
            failedCount: Binding<Int>,
            popupHost: Binding<LoginPopup?>
        ) {
            self.id = id
            self.finishedCount = finishedCount
            self.failedCount = failedCount
            self.popupHost = popupHost
        }

        /// The card's own view, not a login popup sharing this coordinator:
        /// popup outcomes must not drive the card's reload cover or error.
        private func isCardView(_ webView: WKWebView) -> Bool {
            guard let card = WebsiteViewPool.shared.existingView(for: id) else { return false }
            return webView === card
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Main thread by WebKit contract; the writes cross to the view
            // through the bindings, and the content decides whether a reload
            // was actually in flight.
            guard isCardView(webView) else { return }
            Task { @MainActor in
                finishedCount.wrappedValue += 1
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard isCardView(webView), !isCancellation(error) else { return }
            Task { @MainActor in
                failedCount.wrappedValue += 1
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard isCardView(webView), !isCancellation(error) else { return }
            Task { @MainActor in
                failedCount.wrappedValue += 1
            }
        }

        /// Superseded navigations and refused downloads report as failures;
        /// neither is a broken page.
        private func isCancellation(_ error: Error) -> Bool {
            (error as NSError).code == NSURLErrorCancelled
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let isPopup = navigationAction.targetFrame == nil
            let isMain = navigationAction.targetFrame?.isMainFrame ?? true
            switch WebsitePolicy.verdict(url: url, targetFrameIsMain: isMain, isPopup: isPopup) {
            case .allow, .popup:
                // A popup verdict is allowed through rather than cancelled:
                // WebKit then mints the sheet's view via createWebViewWith,
                // which keeps window.opener intact for OAuth-style logins. A
                // manual load would open the page with no opener link.
                decisionHandler(.allow)
            case .cancel:
                decisionHandler(.cancel)
            case .openExternally:
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            // Anything WebKit cannot show is a download, which has no home in
            // a card: refuse it rather than leaving a stalled navigation.
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // WebKit hands us the configuration the popup must be created with —
            // using any other object raises an NSException in createNewPage.
            // It derives from the opener's, so the shared pool and persistent
            // store (and the login session in them) carry over, and the opener
            // link survives because WebKit loads the request into the view
            // returned here.
            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.navigationDelegate = self
            popup.uiDelegate = self
            Task { @MainActor in
                popupHost.wrappedValue = LoginPopup(view: popup)
            }
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            Task { @MainActor in
                popupHost.wrappedValue = nil
            }
        }
    }
}

/// A popup view for the login sheet. Transient on purpose: popups never enter
/// the pool, so they can neither blank a card nor outlive their sheet.
private struct PopupWebView: NSViewRepresentable {
    let view: WKWebView

    func makeNSView(context: Context) -> WKWebView { view }

    func updateNSView(_ webView: WKWebView, context: Context) {}
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
    @State private var isHovering = false
    @FocusState private var focusedControl: PillControl?

    /// One focus identity per pill control: the pill reveals while any of
    /// them holds keyboard focus, so sighted keyboard users see the buttons
    /// VoiceOver already sees through the opacity.
    private enum PillControl {
        case back, forward, reload, menu
    }
    @State private var loadFailed = false
    @State private var popupHost: LoginPopup?
    @State private var hasLoaded = false

    private var entry: WebsiteEntry? {
        guard let id = currentWidgetID else { return nil }
        return store.entry(for: id)
    }

    private var currentURL: URL? {
        guard let raw = entry?.url, let url = URL(string: raw), url.host != nil else { return nil }
        return url
    }

    private var host: String? {
        guard let id = currentWidgetID, let entry = store.entry(for: id) else { return nil }
        return WebsitePolicy.host(of: entry.url)
    }

    /// This card's height span, 1 where the environment is absent (previews).
    private var heightSpan: Int {
        guard let id = currentWidgetID else { return 1 }
        return arrangement?.lanes.joined().first { $0.id == id }?.span.height ?? 1
    }

    /// The pooled view without creating one, for the hover pill: controls
    /// must not conjure a web view for a card that was never opened.
    private var pooledView: WKWebView? {
        guard let id = currentWidgetID else { return nil }
        return WebsiteViewPool.shared.existingView(for: id)
    }

    private var isOriginal: Bool {
        guard let entry else { return true }
        return entry.url == entry.originalURL
    }

    var body: some View {
        GlassCard {
            ZStack {
                if let id = currentWidgetID {
                    WebsiteWebView(
                        id: id,
                        url: currentURL,
                        finishedCount: $finishedCount,
                        failedCount: $failedCount,
                        popupHost: $popupHost
                    )
                    .opacity((loadFailed && !isReloading) ? 0 : reloadOpacity)
                    .disabled(isReloading || loadFailed)
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
                if loadFailed, !isReloading {
                    // The failed page behind may be anything — blank, dark,
                    // half-rendered — so the error draws nothing over it: the
                    // web view is hidden and this reads like Weather's failure
                    // state instead.
                    VStack(alignment: .leading, spacing: Space.one) {
                        Label("Couldn't load \(host ?? "this site")", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Check your connection and try again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Retry") { runReloadSequence() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Retry loading website")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(Space.two)
                    .accessibilityElement(children: .contain)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: CGFloat(heightSpan) * WidgetSize.tall.height)
            .overlay(alignment: .bottomTrailing) { hoverPill }
            .onHover { hovering in isHovering = hovering }
        }
        .opacity(isReloading ? WebsiteReloadStyle.dimmedOpacity : 1)
        .sheet(isPresented: $showURLSheet) {
            urlSheet
        }
        .sheet(item: $popupHost) { popup in
            popupSheet(popup: popup)
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
                loadFailed = false
                hasLoaded = true
                store.markReloaded(id, at: Date())
            } else if !isReloading {
                hasLoaded = true
            }
        }
        .onChange(of: failedCount) { _, _ in
            failReload()
            if !isReloading { awaitingFreshLoad = false }
        }
    }

    /// WebKit owns right-click inside the page, so the card's controls live
    /// in a floating pill that reveals on hover or keyboard focus.
    @ViewBuilder
    private var hoverPill: some View {
        if currentWidgetID != nil {
            HStack(spacing: Space.half) {
                pillButton(systemImage: "chevron.backward", label: "Go back", disabled: !(pooledView?.canGoBack ?? false), focus: .back) { pooledView?.goBack() }
                pillButton(systemImage: "chevron.forward", label: "Go forward", disabled: !(pooledView?.canGoForward ?? false), focus: .forward) { pooledView?.goForward() }
                pillButton(systemImage: "arrow.clockwise", label: "Reload website", focus: .reload) { runReloadSequence() }
                Menu {
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
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.semibold))
                        .frame(width: Layout.headerAccessorySize, height: Layout.headerAccessorySize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverChip()
                .accessibilityLabel("Website options")
                .focused($focusedControl, equals: .menu)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Space.half)
            .padding(.vertical, Space.half)
            .background { GlassFill(Capsule(), cornerRadius: Radius.card) }
            .clipShape(Capsule())
            .overlay { Capsule().strokeBorder(Color.cardStroke, lineWidth: Stroke.hairline) }
            .padding([.trailing, .bottom], Space.oneHalf)
            .opacity(pillVisible ? 1 : 0)
            .allowsHitTesting(pillVisible)
            .animation(.easeInOut(duration: Layout.hudFadeInDuration), value: pillVisible)
        }
    }

    /// One pill control: the header icon-button size with the shared hover chip.
    private func pillButton(systemImage: String, label: String, disabled: Bool = false, focus: PillControl, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: Layout.headerAccessorySize, height: Layout.headerAccessorySize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverChip()
        .disabled(disabled)
        .accessibilityLabel(label)
        .focused($focusedControl, equals: focus)
    }

    /// The pill answers hover and keyboard focus alike: opacity-0 views stay
    /// in the accessibility tree, so a sighted keyboard user needs the focus
    /// path to see what VoiceOver already sees.
    private var pillVisible: Bool { isHovering || focusedControl != nil }

    private func popupSheet(popup: LoginPopup) -> some View {
        VStack(alignment: .leading, spacing: Space.one) {
            Text(host ?? "Website")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            PopupWebView(view: popup.view)
                .frame(minWidth: Layout.websitePopupMinWidth, minHeight: Layout.websitePopupMinHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Spacer()
                Button("Dismiss") { popupHost = nil }
                    .accessibilityLabel("Dismiss login window")
            }
        }
        .padding(Space.two)
    }

    /// Screenshot the stale page, dim the card, and reload underneath. The
    /// snapshot covers the white flash; `finishReload` crossfades it away.
    private func runReloadSequence() {
        guard let id = currentWidgetID, !isReloading else { return }
        loadFailed = false
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
        loadFailed = false
        hasLoaded = true
        store.markReloaded(id, at: Date())
    }

    /// A load that failed: clear any reload cover without stamping, so the
    /// site stays eligible for a retry. Raises the error overlay only for a
    /// load someone asked for — a subframe failing under an idle page is not
    /// a broken card — or when nothing has ever committed yet.
    private func failReload() {
        let wasReloading = isReloading
        if wasReloading {
            reloadTask = nil
            withAnimation(.easeInOut(duration: WebsiteReloadStyle.crossfadeDuration)) {
                snapshot = nil
                reloadOpacity = 1
            }
            isReloading = false
        }
        if wasReloading || awaitingFreshLoad || !hasLoaded {
            loadFailed = true
        }
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
        WebsitePolicy.isAllowed(URL(string: Self.normalizedAddress(draftURL)))
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
        loadFailed = false
        loadFailed = false
    }
}
