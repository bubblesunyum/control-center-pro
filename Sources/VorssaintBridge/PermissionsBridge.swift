// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Combine
import Foundation

/// How the system has answered for one permission. Upstream carries a separate
/// four-case enum per permission plus bare `Bool`s for the two it polls; this
/// is the one shape CCP reads them all through.
public enum PermissionAuthorization: Sendable, Equatable {
    case granted, denied, undetermined, unknown
}

/// The permissions CCP's widgets gate themselves on.
public enum PermissionKind: String, Sendable, CaseIterable {
    case accessibility, screenRecording, fullDiskAccess, notifications, camera, microphone
    /// CoreAudio process taps. Upstream can open its System Settings pane but
    /// offers no status read, and macOS exposes none — so it reports `.unknown`
    /// rather than guessing.
    case audioCapture
}

/// Every permission state read at one instant, so a widget's gate cannot see a
/// half-updated picture.
public struct PermissionSnapshot: Sendable, Equatable {
    public var accessibility: PermissionAuthorization
    public var screenRecording: PermissionAuthorization
    public var fullDiskAccess: PermissionAuthorization
    public var notifications: PermissionAuthorization
    public var camera: PermissionAuthorization
    public var microphone: PermissionAuthorization

    public init(
        accessibility: PermissionAuthorization,
        screenRecording: PermissionAuthorization,
        fullDiskAccess: PermissionAuthorization,
        notifications: PermissionAuthorization,
        camera: PermissionAuthorization,
        microphone: PermissionAuthorization
    ) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.fullDiskAccess = fullDiskAccess
        self.notifications = notifications
        self.camera = camera
        self.microphone = microphone
    }

    public subscript(kind: PermissionKind) -> PermissionAuthorization {
        switch kind {
        case .accessibility: return accessibility
        case .screenRecording: return screenRecording
        case .fullDiskAccess: return fullDiskAccess
        case .notifications: return notifications
        case .camera: return camera
        case .microphone: return microphone
        case .audioCapture: return .unknown
        }
    }
}

/// Upstream's `Permissions` singleton, re-exported. Reads, requests, and the
/// System Settings trip — no policy about what a missing permission means.
@MainActor
public enum SystemPermissions {
    public static var snapshot: PermissionSnapshot {
        let p = Permissions.shared
        return PermissionSnapshot(
            accessibility: p.accessibility ? .granted : .denied,
            screenRecording: p.screenRecording ? .granted : .denied,
            // No API distinguishes "not yet asked" from "refused" for Full Disk
            // Access; upstream probes a protected directory, so absence is all
            // we can honestly report.
            fullDiskAccess: p.fullDiskAccess ? .granted : .denied,
            notifications: authorization(p.notifications),
            camera: authorization(p.camera),
            microphone: authorization(p.microphone))
    }

    public static func refresh() {
        Permissions.shared.refresh()
    }

    /// Prompts where the system offers a prompt, and otherwise opens the
    /// relevant System Settings pane, which for several of these is the only
    /// route a user has.
    public static func request(_ kind: PermissionKind) {
        let permissions = Permissions.shared
        switch kind {
        case .accessibility: permissions.requestAccessibility()
        case .screenRecording: permissions.requestScreenRecording()
        case .fullDiskAccess: permissions.requestFullDiskAccess()
        case .camera: permissions.requestCamera()
        case .microphone: permissions.requestMicrophone()
        case .notifications: permissions.openNotificationSettings()
        case .audioCapture: permissions.openAudioCaptureSettings()
        }
    }

    public static func openSettings(for kind: PermissionKind) {
        let permissions = Permissions.shared
        switch kind {
        case .accessibility: permissions.openAccessibilitySettings()
        case .screenRecording: permissions.openScreenRecordingSettings()
        case .fullDiskAccess: permissions.openFullDiskAccessSettings()
        case .camera: permissions.openCameraSettings()
        case .microphone: permissions.openMicrophoneSettings()
        case .notifications: permissions.openNotificationSettings()
        case .audioCapture: permissions.openAudioCaptureSettings()
        }
    }

    /// Upstream signals a System Settings round trip through the `showGuide`
    /// hook the fork patched in; CCP renders its own inline grant state from it
    /// rather than upstream's floating overlay. See PATCHES.md.
    public static func onSettingsTripNeeded(_ handle: ((PermissionKind) -> Void)?) {
        guard let handle else {
            Permissions.showGuide = nil
            return
        }
        Permissions.showGuide = { kind in
            switch kind {
            case .accessibility: handle(.accessibility)
            case .screenRecording: handle(.screenRecording)
            }
        }
    }

    /// The engine publishes through `ObservableObject`; CCP works in
    /// async/await, and this is the seam where that conversion belongs.
    public static var updates: AsyncStream<PermissionSnapshot> {
        AsyncStream { continuation in
            let cancellable = Permissions.shared.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { _ in
                    // objectWillChange fires in willSet before the @Published storage updates,
                    // so reading snapshot here would yield the previous value. Defer to the
                    // next run-loop turn where the new values are in place.
                    DispatchQueue.main.async { continuation.yield(snapshot) }
                }
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    private static func authorization(
        _ state: Permissions.NotificationPermissionState
    ) -> PermissionAuthorization {
        switch state {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        case .unknown: return .unknown
        }
    }

    private static func authorization(
        _ state: Permissions.CameraPermissionState
    ) -> PermissionAuthorization {
        switch state {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        case .unknown: return .unknown
        }
    }

    private static func authorization(
        _ state: Permissions.MicrophonePermissionState
    ) -> PermissionAuthorization {
        switch state {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        case .unknown: return .unknown
        }
    }
}
