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
    public func chime() {}
}

/// The real time's-up signals: a system notification scheduled at each phase
/// start (it fires even with the panel shut and the app idle) and a soft
/// chime the store plays itself when the panel is open to watch the deadline
/// pass.
///
/// One pending request at a time — a phase start replaces the previous one,
/// and pause/reset/skip withdraws it — so a stale deadline can never ping.
public final class LiveFocusNotifier: FocusNotifier, @unchecked Sendable {
    // Unchecked because UNUserNotificationCenter's thread-safety is a
    // framework guarantee, not one the type system can see; the center is
    // never reassigned after init.
    private static let requestID = "ccp-focus-phase-end"

    private let center: UNUserNotificationCenter

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

    public func chime() {
        NSSound(named: "Glass")?.play()
    }
}
