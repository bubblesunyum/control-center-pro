// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CoreGraphics
import Foundation

/// How long since the user last touched mouse or keyboard, in seconds.
///
/// A passive read — `CGEventSource.secondsSinceLastEventType` never installs
/// a tap, so it needs no Accessibility or Input Monitoring permission. The
/// MiddleClick engine already reads it the same way.
public protocol FocusActivitySource: Sendable {
    func idleSeconds() -> TimeInterval
}

/// The live sensor: the freshest of key, mouse-move, click, drag and scroll.
public struct LiveFocusActivitySource: FocusActivitySource {
    public init() {}

    public func idleSeconds() -> TimeInterval {
        let types: [CGEventType] = [
            .keyDown,
            .mouseMoved,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged,
            .scrollWheel,
        ]
        var freshest = TimeInterval.greatestFiniteMagnitude
        for type in types {
            let idle = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: type
            )
            // The API reports infinity when an event type never fired.
            guard idle.isFinite else { continue }
            freshest = min(freshest, idle)
        }
        return freshest
    }
}
