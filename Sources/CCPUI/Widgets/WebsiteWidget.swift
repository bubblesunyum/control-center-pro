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
        WebsiteConfiguration.applyDesktopAgent(to: webView)
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

    /// The live page's URL — where the user actually is after in-page
    /// navigation — as opposed to the entry URL the pool last loaded. Back,
    /// forward, and Replace-with-current all read this.
    func currentURL(for id: WidgetID) -> URL? {
        views[id.rawValue]?.url
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

    /// Adopt a URL the view already shows as the entry's loaded address —
    /// what Replace-with-current uses to pin the live page without reloading
    /// it. A plain `load` of the identical URL would white-flash, reset the
    /// scroll, and restart media for no navigation at all.
    func noteLoaded(_ id: WidgetID, url: URL) {
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
            // returned here. The preferences are re-pinned — a derived config
            // must never silently lose the opener's window-open grant, which
            // is exactly what a site reports as "blocking popups" — and the
            // view gets a real size: some login flows measure their window on
            // open and bail on a zero rect.
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            let popup = WKWebView(
                frame: CGRect(origin: .zero, size: Layout.websitePopupInitialSize),
                configuration: configuration
            )
            WebsiteConfiguration.applyDesktopAgent(to: popup)
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
    @Environment(\.panelEditor) private var editor
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
    /// The pointer in the corner zone straddling the card's outer bottom-left
    /// edge, or on the bar itself. The whole-card hover is gone on purpose:
    /// WebKit owns the page, so the bar must not answer the entire card.
    @State private var isHoveringPill = false
    /// A pending bar hide, cancelled when the pointer re-enters. Without the
    /// grace the zone-to-bar handoff (adjacent views, unordered events)
    /// flickers the bar on every crossing.
    @State private var hideTask: Task<Void, Never>?
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
    @State private var isImporting = false
    @State private var importedCount: Int?

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
        slot?.span.height ?? 1
    }

    /// The card's drawn height: the live drag size while a grip is held, the
    /// stored rect otherwise. Reading the preview (not just the placement) is
    /// what makes a vertical drag track the finger instead of jumping on
    /// release — the outer lane frame alone cannot stretch this inner frame.
    /// The previewed slot carries both, so there is one height rule with the
    /// shell's rather than a second copy of it here.
    private var drawnHeight: CGFloat {
        guard let id = currentWidgetID else { return WidgetSize.tall.height }
        if let drawn = editor?.drawSize(for: id)?.height { return drawn }
        if let slot, let editor { return editor.previewing(slot).height }
        return CGFloat(heightSpan) * WidgetSize.tall.height
    }

    /// The card's drawn width, for placing the bar: a bar wider than its card
    /// must hang toward the safe side (see `pillPlacement`).
    private var drawnWidth: CGFloat {
        guard let id = currentWidgetID else { return Layout.laneWidth }
        if let drawn = editor?.drawSize(for: id)?.width { return drawn }
        return slot?.width ?? Layout.laneWidth
    }

    /// The slot this card draws, looked up once: span and free rect derive
    /// from the same placement so they can never disagree.
    private var slot: LaneSlot? {
        guard let id = currentWidgetID else { return nil }
        return arrangement?.lanes.joined().first { $0.id == id }
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
            .frame(height: drawnHeight)
        }
        // The bar floats outside the glass, so it sits above the neighbour
        // below while visible rather than sliding under it. Its frame joins
        // the backdrop hit-test (see WebsiteBarFramePreference) so a click on
        // it never reads as backdrop.
        .zIndex(pillVisible ? 10 : 0)
        .overlay(alignment: pillPlacement.alignment) { pillBar }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                // Proximity, not coverage: nothing invisible sits over the
                // page swallowing clicks — the bar answers the pointer being
                // near the card's outer bottom-left corner and the keyboard.
                // Generous by a few points so landing it never needs care.
                let nearCorner = location.x < Self.cornerProximityWidth + Space.two
                    && location.y > drawnHeight - Self.cornerProximityHeight - Space.two
                noteHover(nearCorner)
            case .ended:
                noteHover(false)
            }
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
            hideTask?.cancel()
            hideTask = nil
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

    /// WebKit owns right-click inside the page, so the card's controls live in
    /// a bar pinned to the card's outer bottom-left edge — outside the glass,
    /// straddling the edge, never covering the page. It answers pointer
    /// proximity to that corner (no invisible strip over the page: hover
    /// tracking never swallows a click) and the keyboard: hovering the rest
    /// of the page leaves it hidden. The trigger stays at the bottom-left in
    /// every placement, so the learned hover never goes dead; a short hide
    /// grace covers the handoff from card to bar. When the bar would hang off
    /// screen it flips to another side.
    ///
    /// The bar also reports its frame to the backdrop hit-test while visible
    /// (see PanelOverflowFramePreference): it hangs outside every card frame,
    /// where a click would otherwise read as backdrop and dismiss the panel
    /// under the finger.
    @ViewBuilder
    private var pillBar: some View {
        if currentWidgetID != nil {
            pillContent
                .offset(x: pillPlacement.xOffset, y: pillPlacement.yOffset)
                .onHover(perform: noteHover)
                .background {
                    GeometryReader { proxy in
                        // `offset` shifts drawing post-layout, so the measured
                        // layout frame needs the same shift to match the drawn
                        // bar — a background sits at the pre-offset box.
                        Color.clear.preference(
                            key: PanelOverflowFramePreference.self,
                            value: pillVisible
                                ? [proxy.frame(in: .panel).offsetBy(
                                    dx: pillPlacement.xOffset,
                                    dy: pillPlacement.yOffset
                                )]
                                : []
                        )
                    }
                }
        }
    }

    /// A hover handoff with a grace: leaving the card's corner or the bar
    /// hides the bar a beat later rather than at once, so the pointer
    /// crossing from card to bar (adjacent views, unordered events) never
    /// flickers it. Entering cancels a pending hide.
    private func noteHover(_ hovering: Bool) {
        if hovering {
            hideTask?.cancel()
            hideTask = nil
            isHoveringPill = true
        } else {
            hideTask?.cancel()
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.hoverGraceSeconds))
                guard !Task.isCancelled else { return }
                isHoveringPill = false
            }
        }
    }

    /// The bar's size as drawn: buttons plus capsule padding, estimated for
    /// placement — the bar is hidden until the pointer is already near the
    /// corner, so it never reports its own size for where to hang.
    private static let pillEstimate = CGSize(width: 200, height: 44)
    /// The corner proximity: how near the pointer must be to the card's
    /// bottom-left corner to raise the bar. Wide enough to land, short enough
    /// that the rest of the page never triggers it. A hover threshold, not a
    /// view — nothing covers the page.
    private static let cornerProximityWidth: CGFloat = 120
    private static let cornerProximityHeight: CGFloat = 28
    /// How long the bar lingers after the pointer leaves its corner and bar.
    private static let hoverGraceSeconds: Double = 0.6
    /// How close to the display's bottom the card sits before the bar flips
    /// above it instead of hanging below.
    private static let pillFlipMargin: CGFloat = 60

    /// One of the bar's four hangs: below or above, off the leading or
    /// trailing edge. Default bottom-leading. A bar wider than its card flips
    /// to the trailing edge — hanging left is safe except at the display's
    /// left edge, while hanging right past a right-seated panel is off screen
    /// by construction (the panel sits 8pt from it). A bar below a card near
    /// the display's bottom flips above. The bar is narrower than any grid
    /// card, so the common case never flips at all.
    private enum PillPlacement {
        case belowLeading, belowTrailing, aboveLeading, aboveTrailing

        var alignment: Alignment {
            switch self {
            case .belowLeading: return .bottomLeading
            case .belowTrailing: return .bottomTrailing
            case .aboveLeading: return .topLeading
            case .aboveTrailing: return .topTrailing
            }
        }

        var xOffset: CGFloat {
            switch self {
            case .belowLeading, .aboveLeading: return Space.one
            case .belowTrailing, .aboveTrailing: return -Space.one
            }
        }

        var yOffset: CGFloat {
            switch self {
            case .belowLeading, .belowTrailing: return WebsiteContent.pillEstimate.height
            case .aboveLeading, .aboveTrailing: return -WebsiteContent.pillEstimate.height
            }
        }
    }

    private var pillPlacement: PillPlacement {
        let trailing = drawnWidth < Self.pillEstimate.width + Space.two
        if pillShowsAbove {
            return trailing ? .aboveTrailing : .aboveLeading
        }
        return trailing ? .belowTrailing : .belowLeading
    }

    private var pillShowsAbove: Bool {
        guard let maxY = cardPanelMaxY else { return false }
        // Panel space runs down from the window's top, and the window's top
        // is the visible area's top — so the card's distance from the
        // display's bottom is the visible height minus its panel depth. The
        // height rides on the editor (set by the controller per seat) rather
        // than a screen lookup here, so the view stays pure.
        let screenH = editor?.displayHeight ?? 900
        return screenH - maxY < Self.pillFlipMargin
    }

    /// The card's depth in panel space, for the above/below choice. Nil
    /// before the first layout report — below until known. Zones don't
    /// invalidate (deliberately untracked), but the side is read when hover
    /// or layout state re-evaluates the body — exactly when it matters — so
    /// a settled layout always places correctly.
    private var cardPanelMaxY: CGFloat? {
        guard let id = currentWidgetID else { return nil }
        return editor?.zones.first(where: { $0.id == id })?.frame.maxY
    }

    /// The bar itself: back, forward, reload, and the card's menu.
    @ViewBuilder
    private var pillContent: some View {
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
                Button("Replace with Current URL") { replaceWithCurrentURL() }
                    .disabled(!canReplaceWithCurrent)
                    .accessibilityLabel("Replace with current URL")
                Button("Reset to Original URL") { resetToOriginal() }
                    .disabled(isOriginal)
                    .accessibilityLabel("Reset to original URL")
                Button(importLabel) { runZenImport() }
                    .disabled(isImporting)
                    .accessibilityLabel("Import cookies from Zen browser")
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
        .opacity(pillVisible ? 1 : 0)
        .allowsHitTesting(pillVisible)
        .animation(.easeInOut(duration: Layout.hudFadeInDuration), value: pillVisible)
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

    /// The bar answers the corner zone and keyboard focus alike: opacity-0
    /// views stay in the accessibility tree, so a sighted keyboard user needs
    /// the focus path to see what VoiceOver already sees.
    private var pillVisible: Bool { isHoveringPill || focusedControl != nil }

    /// The live page's URL — where the user is after following links — for
    /// pinning the card to it. Nil before the first commit.
    private var liveURL: URL? {
        guard let id = currentWidgetID else { return nil }
        return WebsiteViewPool.shared.currentURL(for: id)
    }

    /// Pinning is offered only when the page moved somewhere the card doesn't
    /// already name. Compared canonically: WebKit reports `https://x/` for an
    /// entry typed `https://x`, and a fragment scroll is not a new page — both
    /// must not offer a pin that goes nowhere.
    private var canReplaceWithCurrent: Bool {
        guard let live = liveURL, let stored = entry?.url else { return false }
        return Self.canonicalForCompare(live.absoluteString) != Self.canonicalForCompare(stored)
    }

    private static func canonicalForCompare(_ raw: String) -> String {
        var text = raw
        if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
        while text.hasSuffix("/") && text.count > 1 { text.removeLast() }
        return text
    }

    /// Point the card at the live page, keeping its original as the reset
    /// target — the same shape as Change URL, with the address filled in from
    /// where the user already is rather than typed. No navigation: the view
    /// already shows this page, so only the pool's loaded address and the
    /// store move — reloading would flash and restart the page for nothing.
    private func replaceWithCurrentURL() {
        guard let id = currentWidgetID, let live = liveURL else { return }
        takeOverFromReload()
        WebsiteViewPool.shared.noteLoaded(id, url: live)
        store.updateURL(id, to: live.absoluteString)
        store.markReloaded(id, at: Date())
        awaitingFreshLoad = false
    }

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

    /// What the Zen import row says: idle, working, or the count landed.
    private var importLabel: String {
        if isImporting { return "Importing Zen Cookies…" }
        if let count = importedCount {
            return count == 0 ? "Import Zen Cookies (none found)" : "Import Zen Cookies (\(count) added)"
        }
        return "Import Zen Cookies"
    }

    /// Copy Zen's jar into the shared session, then reload so the signed-in
    /// page replaces whatever the anonymous one drew.
    private func runZenImport() {
        guard !isImporting else { return }
        isImporting = true
        importedCount = nil
        Task { @MainActor in
            let count = await ZenCookieImport.importFromZen()
            isImporting = false
            importedCount = count
            if count > 0 { runReloadSequence() }
        }
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
    }
}
