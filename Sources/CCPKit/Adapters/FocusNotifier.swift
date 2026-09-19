// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import Foundation
import UserNotifications

public enum FocusNotificationStatus: Sendable, Equatable {
    case unknown
    case notDetermined
    case authorized
    case denied
}

/// Where time's-up signals go: a scheduled system notification for the
/// panel-closed case, a chime for the panel-open one.
///
/// Status reads are async — `UNUserNotificationCenter` answers on a
/// completion — so the store caches the answer in `notificationStatus` and
/// refreshes it on panel open and after an authorization request.
public protocol FocusNotifier: AnyObject, Sendable {
    func currentStatus() async -> FocusNotificationStatus
    func requestAuthorization() async -> Bool
    func schedule(title: String, body: String, at: Date)
    func cancelScheduled()
    func scheduleReturnNudge()
    func cancelReturnNudge()
    func chime()
}

/// The test stand-in. Stateless, so plain `Sendable` holds — the `@unchecked`
/// is only for the two shapes below that the compiler cannot see through.
public final class NoopFocusNotifier: FocusNotifier, Sendable {
    public init() {}
    public func currentStatus() async -> FocusNotificationStatus { .unknown }
    public func requestAuthorization() async -> Bool { false }
    public func schedule(title: String, body: String, at: Date) {}
    public func cancelScheduled() {}
    public func scheduleReturnNudge() {}
    public func cancelReturnNudge() {}
    public func chime() {}
}

/// The real time's-up signals: a system notification scheduled at each phase
/// start (it fires even with the panel shut and the app idle) and the store's
/// own chime, played on every completion whether the panel is open or not —
/// so a user with notification sounds off still hears the round end.
///
/// One pending request at a time — a phase start replaces the previous one,
/// and pause/reset/skip withdraws it — so a stale deadline can never ping.
public final class LiveFocusNotifier: FocusNotifier, @unchecked Sendable {
    // Unchecked because UNUserNotificationCenter's thread-safety is a
    // framework guarantee, not one the type system can see; the center is
    // never reassigned after init.
    private static let requestID = "ccp-focus-phase-end"
    private static let returnRequestID = "ccp-focus-return-nudge"

    /// The return-nudge category and its Start action. String IDs, so the app
    /// delegate matches the tap without hardcoding them.
    public static let returnCategoryID = "ccp-focus-return"
    public static let startFocusActionID = "ccp-start-focus"

    /// Register once at launch, before any nudge can post.
    public static func registerCategories(
        center: UNUserNotificationCenter = .current()
    ) {
        let start = UNNotificationAction(
            identifier: startFocusActionID,
            title: "Start focus",
            options: [.foreground]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: returnCategoryID,
                actions: [start],
                intentIdentifiers: [],
                options: []
            ),
        ])
    }

    private let center: UNUserNotificationCenter
    // Retained: a throwaway NSSound deallocates mid-play and truncates the
    // chime, and a missing name must fall back rather than fail silently.
    private var chimeSound: NSSound?

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func currentStatus() async -> FocusNotificationStatus {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    public func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func schedule(title: String, body: String, at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(date.timeIntervalSinceNow, 1),
            repeats: false
        )
        center.add(UNNotificationRequest(
            identifier: Self.requestID,
            content: content,
            trigger: trigger
        ))
    }

    public func cancelScheduled() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestID])
    }

    /// One immediate nudge with the Start action. Separate ID from the
    /// phase-end request so the two never withdraw each other. Neutral copy
    /// on purpose: the watch fires on presence after the delay, whether the
    /// user stepped away or simply kept working past it.
    public func scheduleReturnNudge() {
        Self.registerCategories(center: center)
        let content = UNMutableNotificationContent()
        content.title = "Time for another focus?"
        content.body = "Start a focus round when you're ready."
        content.sound = .default
        content.categoryIdentifier = Self.returnCategoryID
        center.add(UNNotificationRequest(
            identifier: Self.returnRequestID,
            content: content,
            trigger: nil
        ))
    }

    public func cancelReturnNudge() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.returnRequestID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.returnRequestID])
    }

    public func chime() {
        if chimeSound == nil { chimeSound = NSSound(named: "Glass") }
        if let chimeSound {
            chimeSound.stop()
            chimeSound.play()
        } else {
            NSSound.beep()
        }
    }
}
