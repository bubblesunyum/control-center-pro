// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// The toggles pane: a row of icon buttons for one-click system actions.
///
/// Today it hosts the Finder "show hidden files" toggle ported from
/// `QuickTogglesService`. Each button is a compact icon-button rather than a full
/// row so the widget stays at `.compact` height and reads as a control strip —
/// the same language Control Center uses for its toggles.
///
/// The widget re-reads Finder state on `activate()` so an external `defaults
/// write` is visible the next time the panel opens, and disables the button
/// while the Finder restart is in flight.
@MainActor
public final class QuickTogglesWidget: CCPWidget {
    public static let descriptor = WidgetDescriptor(
        id: "quick-toggles",
        title: "Toggles",
        symbolName: "switch.2",
        size: .compact
    )

    private let adapter: QuickTogglesAdapter

    public init() {
        self.adapter = QuickTogglesAdapter()
    }

    /// Test seam: a widget backed by a fake source.
    init(source: QuickTogglesSource) {
        self.adapter = QuickTogglesAdapter(source: source)
    }

    public func makeView() -> some View {
        QuickTogglesContent(adapter: adapter)
    }

    public func activate() { adapter.activate() }
    public func deactivate() { adapter.deactivate() }
}

// MARK: - Content

private struct QuickTogglesContent: View {
    @Bindable var adapter: QuickTogglesAdapter

    var body: some View {
        WidgetCard(QuickTogglesWidget.descriptor) {
            HStack(spacing: Space.one) {
                hiddenFilesButton
                Spacer(minLength: 0)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: adapter.hiddenFilesShown)
        .animation(.easeInOut(duration: 0.2), value: adapter.isToggling)
    }

    private var hiddenFilesButton: some View {
        let isOn = adapter.hiddenFilesShown
        return ToggleIconButton(
            title: "Hidden Files",
            subtitle: isOn ? "Shown" : "Hidden",
            systemImage: isOn ? "eye.slash" : "eye",
            isOn: isOn,
            isBusy: adapter.isToggling,
            help: isOn ? "Hide hidden files — Finder will restart" : "Show hidden files — Finder will restart"
        ) {
            adapter.toggleHiddenFiles()
        }
    }
}

// MARK: - Icon button

private struct ToggleIconButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isOn: Bool
    let isBusy: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.half) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(isOn ? Color.widgetAccent : Color.controlFill)
                        .frame(width: Layout.toggleIconSize, height: Layout.toggleIconSize)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .strokeBorder(
                                    isOn ? Color.controlStrokeActive : Color.cardStroke,
                                    lineWidth: Stroke.hairline
                                )
                        )
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(isOn ? .white : .secondary)
                    } else {
                        Image(systemName: systemImage)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(isOn ? Color.white : Color.primary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                VStack(spacing: Space.quarter) {
                    Text(title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(isOn ? Color.widgetAccent : Color.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: Layout.toggleCellWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel("Hidden Files")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityHint("Toggles Finder hidden files. Finder restarts to apply.")
        .help(help)
    }
}
