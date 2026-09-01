// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import Observation

// MARK: - Source

/// Where the Finder hidden-files flag comes from.
///
/// The seam a test stands a fake in for: real Finder preference writes and the
/// subsequent Finder restart are not something a test should trigger.
public protocol QuickTogglesSource: AnyObject, Sendable {
    var hiddenFilesShown: Bool { get }
    func toggleHiddenFiles() async -> Bool
}

/// The real one, talking to `com.apple.finder` directly.
///
/// Mirrors `QuickTogglesService.hiddenFilesShown` and `toggleHiddenFiles()` from
/// vorssaint-utils without depending on the excluded service target: read the
/// `AppleShowAllFiles` default via `CFPreferences`, write the opposite value,
/// synchronize, and restart the Finder so it re-reads the preference at launch.
public final class LiveQuickTogglesSource: QuickTogglesSource {
    private static let finderDomain = "com.apple.finder"
    private static let showAllFilesKey = "AppleShowAllFiles"

    public init() {}

    public var hiddenFilesShown: Bool {
        let value = CFPreferencesCopyAppValue(
            Self.showAllFilesKey as CFString,
            Self.finderDomain as CFString
        )
        return Self.finderFlag(value, defaultValue: false)
    }

    public func toggleHiddenFiles() async -> Bool {
        // Read and write atomically off the main actor so an external `defaults
        // write` that races the toggle is not clobbered by a stale `!old` computed
        // before the background work even starts.
        await Task.detached(priority: .userInitiated) {
            let currentValue = CFPreferencesCopyAppValue(
                Self.showAllFilesKey as CFString,
                Self.finderDomain as CFString
            )
            let current = Self.finderFlag(currentValue, defaultValue: false)
            let next = !current
            CFPreferencesSetAppValue(
                Self.showAllFilesKey as CFString,
                next as CFBoolean,
                Self.finderDomain as CFString
            )
            let synced = CFPreferencesAppSynchronize(Self.finderDomain as CFString)
            guard synced else { return false }
            return await Self.restartFinder()
        }.value
    }

    // MARK: - Finder flag parsing

    /// Finder preferences arrive as real booleans, numbers, or legacy "YES"/"TRUE"/"1"
    /// strings — anything unreadable falls back to the supplied default. Copied
    /// from `QuickTogglesSupport.finderFlag(_:default:)` so the interpretation
    /// matches what vorssaint shows.
    static func finderFlag(_ value: Any?, defaultValue: Bool) -> Bool {
        switch value {
        case let flag as Bool:
            return flag
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            switch string.lowercased() {
            case "yes", "true", "1": return true
            case "no", "false", "0": return false
            default: return defaultValue
            }
        default:
            return defaultValue
        }
    }

    // MARK: - Finder restart

    /// The Finder only reads these preferences at launch, so it has to restart.
    /// For CCP this is `killall Finder` so no Automation consent is required;
    /// launchd relaunches it with the new preference in effect.
    private static func restartFinder() async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = ["Finder"]
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
                return
            }
            // If `killall` hangs (Finder unresponsive), don't block forever:
            // after 5s terminate the helper and report failure so the UI clears
            // the spinner. `terminationHandler` still fires after `terminate()`.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5) {
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}

// MARK: - Adapter

/// The widget's model: exposes the hidden-files flag and toggles it on demand.
///
/// No polling is needed — the value only changes when this widget writes it or
/// when the user flips it outside the app (e.g. via `defaults write`). The adapter
/// re-reads on `activate()` and after each toggle so an external change is visible
/// the next time the panel opens.
@MainActor
@Observable
public final class QuickTogglesAdapter {
    public private(set) var hiddenFilesShown: Bool
    public private(set) var isToggling = false

    @ObservationIgnored private let source: QuickTogglesSource
    @ObservationIgnored private var toggleTask: Task<Void, Never>?

    public convenience init() {
        self.init(source: LiveQuickTogglesSource())
    }

    public init(source: QuickTogglesSource) {
        self.source = source
        self.hiddenFilesShown = source.hiddenFilesShown
    }

    /// Re-read current system state. Called when the panel opens so an external
    /// change is not stale.
    public func refresh() {
        hiddenFilesShown = source.hiddenFilesShown
    }

    /// Idempotent start — a second open while already open does not stack work.
    /// For hidden files there is no timer to start, just a refresh.
    public func activate() {
        refresh()
    }

    public func deactivate() {
        // No ongoing sampling to stop; keep `isToggling` visible until the
        // in-flight restart finishes.
    }

    /// Flip the flag and restart the Finder. While the restart is in flight the
    /// button is disabled; success updates the published flag, failure leaves it
    /// as-is so the next open re-reads the truth.
    public func toggleHiddenFiles() {
        guard !isToggling else { return }
        isToggling = true
        toggleTask?.cancel()
        toggleTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // Ensure the spinner clears even if the Task is cancelled while
                // the Finder helper is still running — otherwise the button stays
                // permanently disabled.
                Task { @MainActor [weak self] in self?.isToggling = false }
            }
            let ok = await self.source.toggleHiddenFiles()
            if Task.isCancelled { return }
            let current = await MainActor.run { self.source.hiddenFilesShown }
            await MainActor.run {
                // The preference is already synchronized even if the Finder restart
                // failed — the Finder will pick it up on its next launch — so we
                // still publish the new value. `ok` tells whether the restart
                // itself succeeded and could be surfaced as a transient error in
                // a future revision.
                self.hiddenFilesShown = current
                _ = ok
            }
        }
    }

    /// Cancel any in-flight toggle. Called when the widget is removed, not on
    /// panel close — a panel close mid-restart should let the restart finish.
    public func cancel() {
        toggleTask?.cancel()
        toggleTask = nil
        isToggling = false
    }

}
