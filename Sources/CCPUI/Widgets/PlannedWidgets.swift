// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

// The v1 set, declared ahead of the engines behind it. The ids are the ones the
// real widgets will keep, so a layout saved against these placeholders survives
// each engine landing.
//
// SystemStatsWidget lives in `SystemStatsWidget.swift` — it is the first real
// widget, over the Metrics and SystemMonitor samplers.

@MainActor
final class NowPlayingWidget: PlaceholderWidget {
    static let descriptor = WidgetDescriptor(
        id: "now-playing",
        title: "Now Playing",
        symbolName: "play.circle"
    )
}

@MainActor
final class QuickTogglesWidget: PlaceholderWidget {
    static let descriptor = WidgetDescriptor(
        id: "quick-toggles",
        title: "Toggles",
        symbolName: "switch.2",
        size: .compact
    )
}

@MainActor
final class ClipboardWidget: PlaceholderWidget {
    static let descriptor = WidgetDescriptor(
        id: "clipboard",
        title: "Clipboard",
        symbolName: "doc.on.clipboard",
        size: .tall
    )
}

@MainActor
final class AudioMixerWidget: PlaceholderWidget {
    static let descriptor = WidgetDescriptor(
        id: "audio-mixer",
        title: "Audio",
        symbolName: "slider.vertical.3",
        permissions: [.audioCapture]
    )
}

/// Where the widgets sit before anyone has moved them.
///
/// It lives beside the registry because it names the same ids: a widget added
/// to one and forgotten in the other is a first launch missing a card. Only
/// first launch reads it — once the arrangement is on disk, that file wins.
public let standardLayout = PanelLayout([
    ["system-stats", "clipboard"],
    ["quick-toggles", "now-playing", "audio-mixer"],
])

/// Every widget this build offers, in the order a gallery lists them.
@MainActor
public func makeStandardRegistry() -> WidgetRegistry {
    let registry = WidgetRegistry()
    registry.register(SystemStatsWidget.self)
    registry.register(QuickTogglesWidget.self)
    registry.register(NowPlayingWidget.self)
    registry.register(AudioMixerWidget.self)
    registry.register(ClipboardWidget.self)
    return registry
}
