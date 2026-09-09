// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import AppKit
import SwiftUI

/// A pomodoro timer: focus stretches broken by short and long breaks.
///
/// Deadline-based — the store holds `phase + endsAt`, so a stretch keeps its
/// end time while the panel is shut and across relaunches. Transitions are
/// manual: a finished stretch waits on its follower rather than starting it.
@MainActor
public final class FocusWidget: CCPWidget {
    public static let descriptor = WidgetDescriptor(
        id: "focus",
        title: "Focus",
        symbolName: "timer",
        size: .regular
    )

    private let store: FocusStore

    public init() {
        self.store = .shared
    }

    public func makeView() -> some View {
        FocusContent(store: store)
    }

    public func activate() { store.panelOpened() }
    public func deactivate() { store.panelClosed() }
}

// MARK: - Content

private struct FocusContent: View {
    @Bindable var store: FocusStore
    @State private var isMenuPresented = false

    private var todayCount: Int? {
        let count = store.completedFocusToday
        return count > 0 ? count : nil
    }

    var body: some View {
        WidgetCard(FocusWidget.descriptor, count: todayCount, accessory: {
            HeaderIconButton(systemImage: "ellipsis", label: "Focus settings") {
                isMenuPresented = true
            }
            .popover(isPresented: $isMenuPresented, arrowEdge: .top) {
                FocusSettingsPopover(store: store)
            }
        }) {
            VStack(alignment: .leading, spacing: Space.one) {
                statusRow
                timerRow
                UsageBar(fraction: progressFraction, tint: progressTint)
                if store.notificationStatus == .denied {
                    notificationGrantRow
                }
            }
            .padding(.bottom, Space.half)
        }
    }

    // MARK: - Rows

    private var statusRow: some View {
        HStack(spacing: Space.half) {
            Text(statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: Space.half)
            roundDots
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(statusText), \(store.focusStreak) of \(store.settings.roundsBeforeLongBreak) focuses")
    }

    private var statusText: String {
        if let phase = store.activePhase {
            return store.isPaused ? "\(phase.title) · paused" : phase.title
        }
        if let next = store.pendingNext {
            switch next {
            case .focus: return "Break over"
            default: return "Focus complete"
            }
        }
        return "Ready"
    }

    private var roundDots: some View {
        HStack(spacing: Space.quarter) {
            ForEach(0..<store.settings.roundsBeforeLongBreak, id: \.self) { index in
                Circle()
                    .fill(index < min(store.focusStreak, store.settings.roundsBeforeLongBreak)
                        ? Color.widgetAccent : Color.cycleDotEmpty)
                    .frame(width: Self.dotDiameter, height: Self.dotDiameter)
            }
        }
    }

    private static let dotDiameter: CGFloat = 6

    private var timerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.one) {
            Text(countdownText)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Spacer(minLength: Space.half)
            controls
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Time remaining, \(countdownText)")
    }

    private var countdownText: String {
        if let remaining = store.remaining(at: store.now) {
            return FocusStore.mmss(remaining)
        }
        if let next = store.pendingNext {
            return FocusStore.mmss(store.duration(of: next))
        }
        return FocusStore.mmss(store.duration(of: .focus))
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: Space.half) {
            if store.isRunning {
                Button("Pause") { store.pause() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Skip") { store.skip() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Skip this phase")
                Button("Reset") { store.reset() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if store.isPaused {
                Button("Resume") { store.resume() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Reset") { store.reset() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if store.pendingNext != nil {
                Button(nextTitle) { store.startNext() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Button("Start focus") { store.start(.focus) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private var nextTitle: String {
        switch store.pendingNext {
        case .focus: "Start focus"
        case .shortBreak: "Start break"
        case .longBreak: "Start long break"
        case nil: "Start focus"
        }
    }

    // MARK: - Progress

    private var progressFraction: Double {
        if store.activePhase != nil {
            return store.fractionElapsed(at: store.now) ?? 0
        }
        return store.pendingNext != nil ? 1 : 0
    }

    private var progressTint: Color? {
        let kind = store.activePhase ?? store.pendingNext
        switch kind {
        case .focus, nil: return nil
        case .shortBreak, .longBreak: return Color.success
        }
    }

    // MARK: - Permission

    /// A denied notification permission never blocks the panel — the timer
    /// works silently, and this row offers the way back. Unasked permissions
    /// show nothing: the first Start carries the system prompt.
    private var notificationGrantRow: some View {
        HStack(spacing: Space.half) {
            Text("Notifications off — no alert when time's up.")
            Spacer(minLength: Space.half)
            Button("Enable") {
                NSWorkspace.shared.open(Self.notificationSettingsURL)
            }
            .buttonStyle(.link)
            .controlSize(.small)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Notifications off. Enable notifications for time's-up alerts.")
    }

    private static let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.notifications")!
}

// MARK: - Settings popover

/// Durations and the cycle length behind the header's three dots — the same
/// trigger and popover language as the Files overflow and closed-notes menus.
///
/// Steppers apply live; a running stretch keeps its deadline, so the popover
/// says so while one runs rather than letting an edit look dead.
private struct FocusSettingsPopover: View {
    @Bindable var store: FocusStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverMenuSectionLabel("Durations")
                .padding(.top, Space.half)
            durationRow(title: "Focus", minutes: binding(for: \.focusMinutes), range: FocusSettings.focusRange, step: 5)
            durationRow(title: "Short break", minutes: binding(for: \.shortBreakMinutes), range: FocusSettings.shortBreakRange, step: 1)
            durationRow(title: "Long break", minutes: binding(for: \.longBreakMinutes), range: FocusSettings.longBreakRange, step: 5)
            PopoverMenuSectionLabel("Cycle")
                .padding(.top, Space.one)
            roundsRow
            if store.activePhase != nil {
                Text("Applies to the next phase — this one keeps its deadline.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Space.one)
                    .padding(.top, Space.half)
            }
            PopoverMenuRow(systemImage: "arrow.counterclockwise", title: "Reset streak") {
                store.resetStreak()
            }
            .padding(.top, Space.half)
        }
        .padding(.vertical, Space.half)
        .padding(.bottom, Space.half)
        .frame(minWidth: Layout.shelfMenuWidth)
    }

    private func binding(for keyPath: WritableKeyPath<FocusSettings, Int>) -> Binding<Int> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: {
                var next = store.settings
                next[keyPath: keyPath] = $0
                store.updateSettings(next)
            }
        )
    }

    private func durationRow(title: String, minutes: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        Stepper(value: minutes, in: range, step: step) {
            HStack(spacing: Space.half) {
                Text(title)
                Spacer(minLength: Space.one)
                Text("\(minutes.wrappedValue) min")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, Space.one)
            .padding(.vertical, Space.half)
        }
        .accessibilityLabel("\(title) duration, \(minutes.wrappedValue) minutes")
    }

    private var roundsRow: some View {
        Stepper(value: binding(for: \.roundsBeforeLongBreak), in: FocusSettings.roundsRange) {
            HStack(spacing: Space.half) {
                Text("Long break every")
                Spacer(minLength: Space.one)
                Text("\(store.settings.roundsBeforeLongBreak) focuses")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, Space.one)
            .padding(.vertical, Space.half)
        }
        .accessibilityLabel("Long break every \(store.settings.roundsBeforeLongBreak) focuses")
    }
}

