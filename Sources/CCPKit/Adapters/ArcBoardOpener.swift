// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import Foundation

/// Refocuses an existing browser tab showing a harness board, if there is one.
///
/// `openBoard` returns true when a tab was focused and the board is handled;
/// false means the caller falls back to its default open (which always opens
/// a fresh tab).
public protocol BoardBrowserOpener: Sendable {
    func openBoard(_ url: URL) async -> Bool
}

/// `BoardBrowserOpener` that reuses an Arc tab instead of opening a new one.
///
/// Fast path first: when Arc is not running there is nothing to refocus, so
/// this returns false without running any script — and therefore without
/// triggering an Automation consent prompt. Otherwise it lists Arc's tab
/// URLs, picks the first one showing this board (see `matchesArcTab`), and
/// selects it.
///
/// Async so the `@MainActor` caller can await without blocking — the hop
/// off the MainActor happens at the await in `LiveHarnessDashboardSource.open`,
/// while AppleScript still blocks its (background) thread. Any script error,
/// denial, or timeout reads as false. This never opens a URL itself.
public struct LiveArcBoardOpener: BoardBrowserOpener, Sendable {
    private static let arcBundleIdentifier = "company.thebrowser.Browser"

    private let isArcRunning: @Sendable () -> Bool
    private let listTabURLs: @Sendable () -> [String]
    private let focusTab: @Sendable (String) -> Bool

    public init() {
        isArcRunning = Self.arcIsRunning
        listTabURLs = Self.arcTabURLs
        focusTab = Self.focusArcTab(withURL:)
    }

    /// Test seam: stand in fakes for the workspace/scripting boundary.
    init(
        isArcRunning: @escaping @Sendable () -> Bool,
        listTabURLs: @escaping @Sendable () -> [String],
        focusTab: @escaping @Sendable (String) -> Bool
    ) {
        self.isArcRunning = isArcRunning
        self.listTabURLs = listTabURLs
        self.focusTab = focusTab
    }

    public func openBoard(_ url: URL) async -> Bool {
        guard isArcRunning() else { return false }
        // A board URL that could never match (non-http, non-loopback, no
        // explicit port) short-circuits before any scripting.
        guard Self.matchesArcTab(tabURL: url.absoluteString, boardURL: url) else { return false }
        guard let hit = listTabURLs().first(where: { Self.matchesArcTab(tabURL: $0, boardURL: url) }) else {
            return false
        }
        return focusTab(hit)
    }

    // MARK: - Matching

    /// Whether an Arc tab URL shows the board at `boardURL`: equal schemes
    /// (both http(s)), both on a loopback host (`localhost` and `127.0.0.1`
    /// match each other), with equal explicit ports. Path and query are
    /// ignored; anything else — including a missing port — is false.
    public static func matchesArcTab(tabURL: String, boardURL: URL) -> Bool {
        guard let boardScheme = boardURL.scheme?.lowercased(),
              boardScheme == "http" || boardScheme == "https",
              let boardHost = boardURL.host?.lowercased(),
              isLoopbackHost(boardHost),
              let boardPort = boardURL.port
        else { return false }
        guard let tab = URLComponents(string: tabURL),
              let tabScheme = tab.scheme?.lowercased(),
              tabScheme == "http" || tabScheme == "https",
              let tabHost = tab.host?.lowercased(),
              isLoopbackHost(tabHost),
              let tabPort = tab.port
        else { return false }
        return tabPort == boardPort && tabScheme == boardScheme
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1"
    }

    // MARK: - Arc scripting surface

    /// Verified against this machine's Arc (`sdef` plus a live
    /// `get URL of every tab of every window` probe): Arc tabs expose a
    /// readable `URL`, windows expose `tabs`, tabs answer `select`, window
    /// `index` is settable to bring a window forward, and `activate`
    /// focuses the app.
    static let listTabsSource = """
        with timeout of 5 seconds
          tell application "Arc"
            get URL of every tab of every window
          end tell
        end timeout
        """

    /// A find-and-select script for the already-matched tab URL: selects the
    /// first tab with exactly this URL, brings its window forward, and
    /// activates Arc. Returns true on success, false when the tab is gone.
    static func focusTabSource(tabURL: String) -> String {
        """
        with timeout of 5 seconds
          tell application "Arc"
            repeat with wi from 1 to count of windows
              repeat with ti from 1 to count of tabs of window wi
                if URL of tab ti of window wi is equal to "\(appleScriptEscape(tabURL))" then
                  select tab ti of window wi
                  set index of window wi to 1
                  activate
                  return true
                end if
              end repeat
            end repeat
            return false
          end tell
        end timeout
        """
    }

    /// Escapes a string for embedding in an AppleScript double-quoted literal.
    static func appleScriptEscape(_ string: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(string.count)
        for character in string {
            if character == "\\" || character == "\"" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    /// Flattens an AppleEvent descriptor tree into every string it contains,
    /// whatever nesting the tab-URL query comes back with. Non-string leaves
    /// (booleans, missing values) are skipped.
    static func collectStrings(_ descriptor: NSAppleEventDescriptor, into out: inout [String]) {
        let count = descriptor.numberOfItems
        if count > 0 {
            for index in 1...count {
                guard let item = descriptor.atIndex(index) else { continue }
                collectStrings(item, into: &out)
            }
        } else if let value = descriptor.stringValue {
            out.append(value)
        }
    }

    private static func arcIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == arcBundleIdentifier
        }
    }

    /// Runs a script in-process, returning nil on any failure — including the
    /// Automation denial (-1743/-1744), which stays a silent nil, never a
    /// throw or a prompt of our own.
    private static func runAppleScript(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result
    }

    private static func arcTabURLs() -> [String] {
        guard let result = runAppleScript(listTabsSource) else { return [] }
        var urls: [String] = []
        collectStrings(result, into: &urls)
        return urls
    }

    private static func focusArcTab(withURL tabURL: String) -> Bool {
        guard let result = runAppleScript(focusTabSource(tabURL: tabURL)) else { return false }
        return result.booleanValue
    }
}
