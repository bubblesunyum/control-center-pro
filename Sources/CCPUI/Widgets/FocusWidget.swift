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
    @State private var isDurationsEditorPresented = false
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
        WidgetCard(descriptor, count: todayCount) {
            VStack(alignment: .leading, spacing: Space.one) {
                mainRow
                durationsRow
                if store.notificationStatus == .denied {
                    notificationGrantRow
                }
            }
        }
        .celebrationGlow(isActive: isAwaitingAck)
        .animation(.snappy, value: descriptor.title)
        .onChange(of: store.pendingNext) { isAcknowledged = false }
    }

    // MARK: - Rows

    private var mainRow: some View {
        HStack(spacing: Space.two) {
            ProgressRing(
                fraction: progressFraction,
                tint: progressTint,
                isBreathing: store.isRunning
            )
            .frame(width: Self.ringDiameter, height: Self.ringDiameter)
            Text(countdownText)
                .font(.title.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(isLastMinute ? Color.urgent : Color.primary)
                .scaleEffect(heartbeat && !reduceMotion ? 1.05 : 1)
                .animation(.easeInOut(duration: 0.45), value: heartbeat)
                .accessibilityLabel("\(descriptor.title)\(store.isPaused ? ", paused" : ""), \(countdownText) remaining")
            Spacer(minLength: Space.half)
            controls
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

    /// Media controls in countdown order: reset, pause, skip. The pause that
    /// carries the phase is prominent; the rest stay quiet until the pointer
    /// lands. One look for every state — a play button starts, whatever waits.
    @ViewBuilder
    private var controls: some View {
        HStack(spacing: Space.quarter) {
            if store.isRunning {
                MediaButton(systemImage: "arrow.counterclockwise", label: "Reset timer") {
                    store.reset()
                }
                MediaButton(systemImage: "pause.fill", label: "Pause", isProminent: true) {
                    store.pause()
                }
                MediaButton(systemImage: "forward.fill", label: "Skip this phase") {
                    store.skip()
                }
            } else if store.isPaused {
                MediaButton(systemImage: "arrow.counterclockwise", label: "Reset timer") {
                    store.reset()
                }
                MediaButton(systemImage: "play.fill", label: "Resume", isProminent: true) {
                    store.resume()
                }
            } else if store.pendingNext != nil {
                MediaButton(systemImage: "play.fill", label: nextTitle, isProminent: true) {
                    store.startNext()
                }
            } else {
                MediaButton(systemImage: "play.fill", label: "Start focus", isProminent: true) {
                    store.start(.focus)
                }
            }
        }
    }

    private var nextTitle: String {
        switch store.pendingNext {
        case .shortBreak: "Start break"
        case .focus, nil: "Start focus"
        }
    }

    // MARK: - Durations

    /// Both intervals on one row, straight from the settings: tapping either
    /// opens the editor. A zero break reads as Off — that is the off switch.
    private var durationsRow: some View {
        HStack(spacing: Space.half) {
            durationPill(
                systemImage: "timer",
                title: "Focus",
                text: "\(store.settings.focusMinutes) min",
                label: "Focus length, \(store.settings.focusMinutes) minutes. Change durations."
            )
            durationPill(
                systemImage: "mug.fill",
                title: "Break",
                text: store.settings.breaksEnabled ? "\(store.settings.shortBreakMinutes) min" : "Off",
                label: store.settings.breaksEnabled
                    ? "Break length, \(store.settings.shortBreakMinutes) minutes. Change durations."
                    : "Breaks off. Change durations."
            )
        }
        .popover(isPresented: $isDurationsEditorPresented, arrowEdge: .bottom) {
            FocusSettingsPopover(store: store)
        }
    }

    private func durationPill(systemImage: String, title: String, text: String, label: String) -> some View {
        Button { isDurationsEditorPresented = true } label: {
            HStack(spacing: Space.half) {
                Image(systemName: systemImage)
                Text(title)
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Space.one)
            .padding(.vertical, Space.half)
            .background(Capsule().fill(Color.controlFill))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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

/// Both intervals as sliders behind the duration pills. Sliders apply live;
/// a running stretch keeps its deadline, and new values start next phase.
/// Dragging break all the way down reads Off — that is how breaks turn off.
private struct FocusSettingsPopover: View {
    @Bindable var store: FocusStore

    var body: some View {
        VStack(alignment: .leading, spacing: Space.one) {
            sliderRow(
                systemImage: "timer",
                title: "Focus",
                value: sliderBinding(for: \.focusMinutes),
                range: doubleRange(FocusSettings.focusRange),
                step: 5,
                presets: [15, 25, 50]
            )
            sliderRow(
                systemImage: "mug.fill",
                title: "Break",
                value: sliderBinding(for: \.shortBreakMinutes),
                range: doubleRange(FocusSettings.shortBreakRange),
                step: 1,
                presets: [0, 5, 15],
                offText: "Off"
            )
        }
        .padding(Space.oneHalf)
        .frame(minWidth: Layout.shelfMenuWidth)
    }

    private func sliderBinding(for keyPath: WritableKeyPath<FocusSettings, Int>) -> Binding<Double> {
        Binding(
            get: { Double(store.settings[keyPath: keyPath]) },
            set: {
                var next = store.settings
                next[keyPath: keyPath] = Int($0)
                store.updateSettings(next)
            }
        )
    }

    private func doubleRange(_ range: ClosedRange<Int>) -> ClosedRange<Double> {
        Double(range.lowerBound)...Double(range.upperBound)
    }

    private func sliderRow(
        systemImage: String,
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        presets: [Int],
        offText: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.half) {
            HStack(spacing: Space.half) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer(minLength: Space.one)
                Text(readout(value: Int(value.wrappedValue), offText: offText))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.primary)
            }
            .font(.caption.weight(.medium))
            Slider(value: value, in: range, step: step) {
                Text(title)
            }
            .accessibilityLabel("\(title) duration")
            HStack(spacing: Space.quarter) {
                ForEach(presets, id: \.self) { preset in
                    presetChip(preset: preset, title: title, value: value, offText: offText)
                }
            }
        }
    }

    private func readout(value: Int, offText: String?) -> String {
        if value == 0, let offText { return offText }
        return "\(value) min"
    }

    private func presetChip(preset: Int, title: String, value: Binding<Double>, offText: String?) -> some View {
        let isSelected = Int(value.wrappedValue) == preset
        let chipText = preset == 0 ? offText ?? "0" : "\(preset)"
        return Button(chipText) {
            value.wrappedValue = Double(preset)
        }
        .buttonStyle(.plain)
        .font(.caption2.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(isSelected ? .white : .secondary)
        .padding(.horizontal, Space.one)
        .padding(.vertical, Space.quarter)
        .background(Capsule().fill(isSelected ? Color.widgetAccent : Color.controlFill))
        .accessibilityLabel(offText != nil && preset == 0
            ? "Turn breaks off" : "\(title), \(preset) minutes")
    }
}

/// One round media button: quiet circle until the pointer lands, accent disc
/// when it carries the phase. Same size and language in every state, so the
/// row never reflows as the timer moves through them.
private struct MediaButton: View {
    let systemImage: String
    let label: String
    var isProminent: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(isProminent ? .white : isHovered ? .primary : .secondary)
                .frame(width: Self.diameter, height: Self.diameter)
                .background(Circle().fill(
                    isProminent ? Color.widgetAccent : isHovered ? Color.controlFill : Color.clear
                ))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { isHovered = $0 }
    }

    private static let diameter: CGFloat = 32
}

