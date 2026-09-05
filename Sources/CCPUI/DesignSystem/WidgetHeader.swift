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
    private let accessory: Accessory

    public init(
        _ descriptor: WidgetDescriptor,
        count: Int? = nil,
        isAccessoryExpanded: Bool = false,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.descriptor = descriptor
        self.count = count
        self.isAccessoryExpanded = isAccessoryExpanded
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
    init(_ descriptor: WidgetDescriptor, count: Int? = nil) {
        self.init(descriptor, count: count) { EmptyView() }
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
/// Deliberately chromeless — no fill, no stroke. Header buttons are a quiet
/// toolbar, not controls calling for attention; a button that needs emphasis
/// says so with `isActive`, which tints the glyph itself.
public struct HeaderIconButton: View {
    private let systemImage: String
    private let label: String
    private let isActive: Bool
    private let action: () -> Void

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
        .foregroundStyle(isActive ? Color.accentColor : .secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}
