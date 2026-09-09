// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import AppKit
import SwiftUI

/// A pomodoro timer: focus stretches broken by breaks.
///
/// Deadline-based — the store holds `phase + endsAt`, so a stretch keeps its
/// end time while the panel is shut and across relaunches. Transitions are
/// manual: a finished stretch waits on its follower rather than starting it.
/// The completion chime is the store's own sound and plays whether the panel
/// is open or not, separate from the scheduled notification.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isMenuPresented = false
    @State private var isAcknowledged = false

    private var todayCount: Int? {
        let count = store.completedFocusToday
        return count > 0 ? count : nil
    }

    /// The card title names the phase — "Focus" or "Focus Break" — so the
    /// labelled status row the card used to wear is gone. A derived copy of
    /// the static descriptor: identity and icon stay intrinsic, only the
    /// title follows the clock.
    private var descriptor: WidgetDescriptor {
        let base = FocusWidget.descriptor
        return WidgetDescriptor(
            id: base.id,
            title: titlePhase?.isBreak == true ? "Focus Break" : "Focus",
            symbolName: base.symbolName,
            size: base.size
        )
    }

    /// The phase the title names: the running one, or the one waiting to
    /// start — the same phase the countdown and the Start button describe.
    /// Idle names nothing and reads as Focus.
    private var titlePhase: FocusPhase? {
        store.activePhase ?? store.pendingNext
    }

    /// Waiting on the next phase and not yet answered — the glow's lifetime.
    private var isAwaitingAck: Bool {
        store.pendingNext != nil && !isAcknowledged
    }

    var body: some View {
        WidgetCard(descriptor, count: todayCount, accessory: {
            HeaderIconButton(systemImage: "ellipsis", label: "Focus settings") {
                isMenuPresented = true
            }
            .popover(isPresented: $isMenuPresented, arrowEdge: .top) {
                FocusSettingsPopover(store: store)
            }
        }) {
            VStack(alignment: .leading, spacing: Space.one) {
                mainRow
                if store.notificationStatus == .denied {
                    notificationGrantRow
                }
            }
            .padding(.bottom, Space.half)
        }
        .celebrationGlow(isActive: isAwaitingAck)
        .animation(.snappy, value: descriptor.title)
        .onChange(of: store.pendingNext) { isAcknowledged = false }
    }

    // MARK: - Rows

    private var mainRow: some View {
        HStack(spacing: Space.one) {
            ProgressRing(
                fraction: progressFraction,
                tint: progressTint,
                isBreathing: store.isRunning
            )
            .frame(width: Self.ringDiameter, height: Self.ringDiameter)
            VStack(alignment: .leading, spacing: Space.half) {
                Text(countdownText)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(isLastMinute ? Color.urgent : Color.primary)
                    .scaleEffect(heartbeat && !reduceMotion ? 1.05 : 1)
                    .animation(.easeInOut(duration: 0.45), value: heartbeat)
                    .accessibilityLabel("\(descriptor.title)\(store.isPaused ? ", paused" : ""), \(countdownText) remaining")
                controls
            }
            Spacer(minLength: Space.half)
            if isAwaitingAck {
                CelebrationSeal(accessibilityLabel: "Acknowledge completion") {
                    isAcknowledged = true
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private static let ringDiameter: CGFloat = 48

    /// The last-minute heartbeat: flips every second under a minute to go,
    /// which replays the pop. Running phases only — breaks, pauses and the
    /// between-phase wait hold still.
    private var heartbeat: Bool {
        guard isLastMinute else { return false }
        return Int(store.remaining(at: store.now) ?? 0) % 2 == 0
    }

    private var isLastMinute: Bool {
        guard store.isRunning, let remaining = store.remaining(at: store.now) else {
            return false
        }
        return remaining < 60
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
        case .shortBreak: "Start break"
        case .focus, nil: "Start focus"
        }
    }

    // MARK: - Progress

    private var progressFraction: Double {
        if store.activePhase != nil {
            return store.fractionElapsed(at: store.now) ?? 0
        }
        return store.pendingNext != nil ? 1 : 0
    }

    private var progressTint: Color {
        if isLastMinute { return Color.urgent }
        switch store.activePhase ?? store.pendingNext {
        case .focus, nil: return Color.widgetAccent
        case .shortBreak: return Color.success
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

/// Durations and the breaks switch behind the header's three dots — the same
/// trigger and popover language as the Files overflow and closed-notes menus.
///
/// Steppers apply live; a running stretch keeps its deadline, so the popover
/// says so while one runs rather than letting an edit look dead.
private struct FocusSettingsPopover: View {
    @Bindable var store: FocusStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: breaksBinding) {
                HStack(spacing: Space.half) {
                    Text("Take breaks")
                    Spacer(minLength: Space.one)
                }
                .font(.caption)
                .padding(.horizontal, Space.one)
                .padding(.vertical, Space.half)
            }
            .accessibilityLabel("Take breaks between focus stretches")
            PopoverMenuSectionLabel("Durations")
                .padding(.top, Space.one)
            durationRow(title: "Focus", minutes: binding(for: \.focusMinutes), range: FocusSettings.focusRange, step: 5)
            durationRow(title: "Break", minutes: binding(for: \.shortBreakMinutes), range: FocusSettings.shortBreakRange, step: 1)
                .disabled(!store.settings.breaksEnabled)
            if store.activePhase != nil {
                Text("Applies to the next phase — this one keeps its deadline.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Space.one)
                    .padding(.top, Space.half)
            }
        }
        .padding(Space.oneHalf)
        .frame(minWidth: Layout.shelfMenuWidth)
    }

    private var breaksBinding: Binding<Bool> {
        Binding(
            get: { store.settings.breaksEnabled },
            set: {
                var next = store.settings
                next.breaksEnabled = $0
                store.updateSettings(next)
            }
        )
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
}

