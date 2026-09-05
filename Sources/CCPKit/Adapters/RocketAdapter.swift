// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import ApplicationServices
import Foundation
import Observation

/// What asking Rocket to show its status menu came to.
public enum RocketMenuOutcome: Sendable, Equatable {
    /// Rocket's own menu is open in the menu bar.
    case shown
    /// Rocket wasn't running, so it was launched instead of pressed.
    case launched
    case notInstalled
    /// CCP is not Accessibility-trusted. The system prompt has been shown;
    /// the next tap after granting works.
    case needsAccessibility
    /// Rocket is running but its status item could not be pressed.
    case failed
}

// MARK: - Source

/// The seam a test stands a fake in for: process lookup, launching, and the
/// Accessibility press are not things a test should trigger.
public protocol RocketSource: AnyObject, Sendable {
    var isInstalled: Bool { get }
    var isRunning: Bool { get }
    var isAccessibilityTrusted: Bool { get }
    func launch()
    /// Show the system Accessibility prompt. The grant only takes effect on
    /// the next press — trust cannot be used in the same call that asks.
    func requestAccessibilityTrust()
    /// Press Rocket's status item so its own menu opens. Must be called off
    /// the main actor: the Accessibility calls can block up to the messaging
    /// timeout when Rocket is wedged.
    func pressStatusMenu() -> RocketPressResult
}

public enum RocketPressResult: Sendable, Equatable {
    case pressed
    case notRunning
    case itemNotFound
    case untrusted
}

/// The real one, talking to NSWorkspace and Rocket's Accessibility tree.
public final class LiveRocketSource: RocketSource {
    public static let bundleID = "net.matthewpalmer.Rocket"
    /// The AXDescription Rocket's status item exposes, verified live against
    /// 1.9.5. The item is unnamed, so the description is the match — the app
    /// menu's items all carry titles instead.
    public static let statusItemDescription = "status menu"

    private static let messagingTimeout: Float = 0.5

    public init() {}

    public var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
    }

    public var isRunning: Bool { Self.runningApplication() != nil }

    public var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    public func launch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    public func requestAccessibilityTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public func pressStatusMenu() -> RocketPressResult {
        guard AXIsProcessTrusted() else { return .untrusted }
        guard let app = Self.runningApplication() else { return .notRunning }
        guard let item = Self.statusItem(pid: app.processIdentifier) else { return .itemNotFound }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success ? .pressed : .itemNotFound
    }

    private static func runningApplication() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
    }

    private static func statusItem(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        for bar in children(of: app) where role(of: bar) == "AXMenuBar" {
            for item in children(of: bar) where isStatusItem(item) {
                return item
            }
        }
        return nil
    }

    /// Whether an element is Rocket's status item rather than an app-menu
    /// item: icon-only, so untitled. The raw AXDescription is nil — System
    /// Events synthesizes "status menu" for the same element, so that string
    /// is accepted too in case some OS versions expose it directly.
    static func isStatusItem(description: String?, title: String?, role: String?) -> Bool {
        role == "AXMenuBarItem" && (title ?? "").isEmpty
            && (description == nil || description == statusItemDescription)
    }

    private static func isStatusItem(_ element: AXUIElement) -> Bool {
        isStatusItem(description: stringAttribute("AXDescription", of: element),
                     title: stringAttribute("AXTitle", of: element),
                     role: role(of: element))
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children
    }

    private static func role(of element: AXUIElement) -> String? {
        stringAttribute(kAXRoleAttribute as String, of: element)
    }

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

// MARK: - Adapter

/// The Tools strip's model for Rocket: installed/running state plus the
/// show-the-menu action.
///
/// Rocket keeps working with its icon hidden — Tahoe's Allow-in-Menu-Bar
/// toggle only stops painting it; the status item stays in the Accessibility
/// tree — so this adapter is what gives the hidden icon back its jobs.
@MainActor
@Observable
public final class RocketAdapter {
    public private(set) var isInstalled: Bool
    public private(set) var isRunning: Bool
    public var isAccessibilityTrusted: Bool { source.isAccessibilityTrusted }

    @ObservationIgnored private let source: RocketSource
    @ObservationIgnored private let notifications: NotificationCenter
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// The system trust prompt is hostile in multiples, so it fires at most
    /// once per adapter lifetime. A grant takes effect on the next press
    /// without any prompt, so no reset is needed — and a deny just keeps
    /// reporting `.needsAccessibility` behind the widget's HUD.
    @ObservationIgnored private var promptedForTrust = false

    public convenience init() {
        self.init(source: LiveRocketSource())
    }

    public init(source: RocketSource,
                notifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.source = source
        self.notifications = notifications
        self.isInstalled = source.isInstalled
        self.isRunning = source.isRunning
    }

    /// Re-read and start watching launch/terminate while the panel is open.
    /// Idempotent — a second open does not stack observers.
    public func activate() {
        guard observers.isEmpty else { return }
        refresh()
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] as [NSNotification.Name] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
    }

    public func deactivate() {
        for observer in observers { notifications.removeObserver(observer) }
        observers.removeAll()
    }

    public func refresh() {
        isInstalled = source.isInstalled
        isRunning = source.isRunning
    }

    /// Show Rocket's own status menu. Launches Rocket when it is stopped;
    /// shows the system Accessibility prompt once when untrusted. The press
    /// itself runs off the main actor so a wedged Rocket cannot hang the UI.
    public func showMenu() async -> RocketMenuOutcome {
        guard source.isInstalled else { return .notInstalled }
        guard source.isRunning else {
            source.launch()
            refresh()
            return .launched
        }
        let press = await Task.detached(priority: .userInitiated) { [source] in
            source.pressStatusMenu()
        }.value
        switch press {
        case .pressed:
            return .shown
        case .notRunning:
            // Raced a quit between the check and the press.
            source.launch()
            refresh()
            return .launched
        case .untrusted:
            if !promptedForTrust {
                promptedForTrust = true
                source.requestAccessibilityTrust()
            }
            return .needsAccessibility
        case .itemNotFound:
            // Either Rocket quit under us or — the common case right after a
            // launch — it is running but hasn't created its status item yet.
            // Re-read rather than trust the pre-press check.
            guard source.isRunning else {
                source.launch()
                refresh()
                return .launched
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let retry = await Task.detached(priority: .userInitiated) { [source] in
                source.pressStatusMenu()
            }.value
            return retry == .pressed ? .shown : .failed
        }
    }
}
