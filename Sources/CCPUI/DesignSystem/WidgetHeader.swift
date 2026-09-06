// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import SwiftUI

/// The line every widget wears above its content: symbol, title, an optional
/// count, and an optional control on the trailing edge.
///
/// It exists so a dozen unrelated widgets agree without any of them saying so.
/// A widget that wants a button up here reaches for the `accessory` builder
/// rather than drawing its own header a size and a colour away from everyone
/// else's — the moment two headers disagree, the panel stops reading as one
/// surface.
///
/// Occasionally the accessory needs the whole row — a search field taking over
/// the header, say. `isAccessoryExpanded` gives it that: the title fades out
/// but the leading symbol stays put, and the accessory stretches to fill what
/// the title left behind. The hold-to-edit target stays the full row either
/// way; only its button traits rest while expanded, so the field inside keeps
/// its own accessibility identity.
public struct WidgetHeader<Accessory: View>: View {
    private let descriptor: WidgetDescriptor
    private let count: Int?
    private let isAccessoryExpanded: Bool
    private let isMinimized: Bool?
    private let onToggleMinimized: (() -> Void)?
    private let accessory: Accessory

    public init(
        _ descriptor: WidgetDescriptor,
        count: Int? = nil,
        isAccessoryExpanded: Bool = false,
        isMinimized: Bool? = nil,
        onToggleMinimized: (() -> Void)? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.descriptor = descriptor
        self.count = count
        self.isAccessoryExpanded = isAccessoryExpanded
        self.isMinimized = isMinimized
        self.onToggleMinimized = onToggleMinimized
        self.accessory = accessory()
    }

    @Environment(\.panelEditor) private var panelEditor
    @Environment(\.currentWidgetID) private var currentWidgetID

    public var body: some View {
        HStack(spacing: Space.half) {
            Label {
                if !isAccessoryExpanded {
                    HStack(spacing: Space.half) {
                        Text(descriptor.title)
                            .lineLimit(1)
                        if descriptor.isMinimizable, let isMinimized, let onToggleMinimized {
                            MinimizeCaret(
                                title: descriptor.title,
                                isMinimized: isMinimized,
                                toggle: onToggleMinimized
                            )
                        }
                        if let count {
                            CountBadge(count: count, of: descriptor.title)
                        }
                    }
                    .transition(.opacity)
                }
            } icon: {
                Image(systemName: descriptor.symbolName)
            }
            .font(.headline)
            .foregroundStyle(.primary)
            .accessibilityHidden(isAccessoryExpanded)
            if !isAccessoryExpanded {
                Spacer(minLength: 0)
            }
            accessory
                .frame(maxWidth: isAccessoryExpanded ? .infinity : nil, alignment: .trailing)
        }
        .frame(minHeight: Layout.headerAccessorySize)
        .contentShape(Rectangle())
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: HeaderFramePreference.self,
                    value: currentWidgetID.map { [HeaderFrame(id: $0, frame: proxy.frame(in: .panel))] } ?? []
                )
            }
        }
        .accessibilityAddTraits(isAccessoryExpanded ? [] : .isButton)
        .accessibilityHint(isAccessoryExpanded ? "" : "Hold to edit widgets")
        .accessibilityAction {
            guard !isAccessoryExpanded, let editor = panelEditor, !editor.isEditing else { return }
            withAnimation(.snappy) { editor.startEditing() }
        }
        .animation(.snappy, value: isAccessoryExpanded)
    }
}

public extension WidgetHeader where Accessory == EmptyView {
    init(_ descriptor: WidgetDescriptor, count: Int? = nil, isMinimized: Bool? = nil, onToggleMinimized: (() -> Void)? = nil) {
        self.init(descriptor, count: count, isMinimized: isMinimized, onToggleMinimized: onToggleMinimized) { EmptyView() }
    }
}

/// The caret that minimizes a widget to its summary form and back.
///
/// It rides immediately after the title — the thing it collapses — rather than
/// in the trailing accessory, so the eye reads it as part of the name. Same
/// chevron language as the section headers inside the cards.
private struct MinimizeCaret: View {
    let title: String
    let isMinimized: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isMinimized ? "chevron.right" : "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isMinimized ? "Expand \(title)" : "Minimize \(title)")
        .accessibilityLabel(isMinimized ? "Expand \(title)" : "Minimize \(title)")
        .accessibilityValue(isMinimized ? "Minimized" : "Expanded")
        .accessibilityHint(isMinimized ? "Shows the full \(title) widget" : "Collapses \(title) to its summary")
    }
}

/// The count that rides beside a title — how many clips, how many items.
private struct CountBadge: View {
    let count: Int
    let of: String

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .padding(.horizontal, Space.half)
            .padding(.vertical, Space.quarter / 2)
            .background(Capsule().fill(Color.controlFill))
            .overlay(Capsule().strokeBorder(Color.cardStroke, lineWidth: Stroke.hairline))
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(count) in \(of)")
    }
}

/// A bare icon button that sits in a widget header without pushing the
/// title's line height around.
///
/// Quiet until the pointer lands: no fill at rest, then the same hover chip
/// the Notes plus wears — one step brighter, over a muted fill.
public struct HeaderIconButton: View {
    private let systemImage: String
    private let label: String
    private let isActive: Bool
    private let action: () -> Void

    @State private var isHovered = false

    public init(
        systemImage: String,
        label: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.label = label
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: Layout.headerAccessorySize, height: Layout.headerAccessorySize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : isHovered ? Color.primary : .secondary)
        .background {
            RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
                .fill(isHovered ? Color.controlFill : Color.clear)
        }
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
