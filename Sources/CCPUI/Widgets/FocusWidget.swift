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
        WidgetCard(descriptor, count: todayCount, accessory: {
            intervalPill
        }) {
            VStack(alignment: .leading, spacing: Space.one) {
                mainRow
                if store.notificationStatus == .denied {
                    notificationGrantRow
                }
            }
            // The card stands at its height floor with room to spare — center
            // the content so the air reads equal on every side.
            .frame(maxHeight: .infinity, alignment: .center)
        }
        // A tap anywhere quiet answers the celebration — buttons keep their
        // own actions, and answering twice is a no-op either way.
        .contentShape(Rectangle())
        .onTapGesture {
            if isAwaitingAck { isAcknowledged = true }
        }
        .accessibilityActions {
            if isAwaitingAck {
                Button("Acknowledge completion") { isAcknowledged = true }
            }
        }
        .celebrationGlow(isActive: isAwaitingAck)
        .animation(.snappy, value: descriptor.title)
        .onChange(of: store.pendingNext) { isAcknowledged = false }
    }

    // MARK: - Rows

    /// The transport: pause/play rides bare in the ring's center, reset and
    /// skip hold the trailing edge. One arrangement in every state, so the
    /// row never reflows.
    private var mainRow: some View {
        HStack(spacing: Space.two) {
            ZStack {
                ProgressRing(
                    fraction: progressFraction,
                    tint: progressTint,
                    isBreathing: store.isRunning
                )
                // Bare glyph on empty glass: adaptive primary, white in dark
                // and black in light, since a fixed white vanishes on light
                // glass. The whole ring is the target.
                Button(action: centerAction) {
                    Image(systemName: centerIcon)
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.primary)
                        .frame(width: Self.ringDiameter, height: Self.ringDiameter)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(centerLabel)
            }
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
        }
    }

    private var centerIcon: String {
        store.isRunning ? "pause.fill" : "play.fill"
    }

    private var centerLabel: String {
        if store.isRunning { return "Pause" }
        if store.isPaused { return "Resume" }
        if store.pendingNext != nil { return nextTitle }
        return "Start focus"
    }

    private func centerAction() {
        if store.isRunning { store.pause() }
        else if store.isPaused { store.resume() }
        else if store.pendingNext != nil { store.startNext() }
        else { store.start(.focus) }
    }

    private static let ringDiameter: CGFloat = 56

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

    /// What the trailing edge holds: reset and skip while running, reset
    /// while paused, nothing otherwise. Transport lives in the ring, so the
    /// row never reflows between states.
    @ViewBuilder
    private var controls: some View {
        HStack(spacing: Space.quarter) {
            if store.isRunning {
                MediaButton(systemImage: "arrow.counterclockwise", label: "Reset timer") {
                    store.reset()
                }
                MediaButton(systemImage: "forward.fill", label: "Skip this phase") {
                    store.skip()
                }
            } else if store.isPaused {
                MediaButton(systemImage: "arrow.counterclockwise", label: "Reset timer") {
                    store.reset()
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

    /// Both intervals in one pill on the header's trailing edge: tapping it
    /// opens the editor. A zero break reads as Off — that is the off switch.
    private var intervalPill: some View {
        Button { isDurationsEditorPresented = true } label: {
            HStack(spacing: Space.one) {
                HStack(spacing: Space.half) {
                    Image(systemName: "timer")
                    Text("\(store.settings.focusMinutes) min")
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .frame(minWidth: Self.pillValueWidth, alignment: .trailing)
                }
                Circle()
                    .fill(.tertiary)
                    .frame(width: Self.pillSeparatorDiameter, height: Self.pillSeparatorDiameter)
                HStack(spacing: Space.half) {
                    Image(systemName: "mug.fill")
                    Text(store.settings.breaksEnabled ? "\(store.settings.shortBreakMinutes) min" : "Off")
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .frame(minWidth: Self.pillValueWidth, alignment: .trailing)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Space.one)
            .padding(.vertical, Space.half)
            .background(Capsule().fill(Color.controlFill))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(intervalPillLabel)
        .popover(isPresented: $isDurationsEditorPresented, arrowEdge: .top) {
            FocusSettingsPopover(store: store)
        }
    }

    private var intervalPillLabel: String {
        let focus = "Focus length, \(store.settings.focusMinutes) minutes"
        let rest = store.settings.breaksEnabled
            ? "break length, \(store.settings.shortBreakMinutes) minutes"
            : "breaks off"
        return "\(focus), \(rest). Change durations."
    }

    private static let pillSeparatorDiameter: CGFloat = 3
    /// Wide enough for the longest readout ("120 min") so dragging a value
    /// never resizes the pill — and never walks the popover anchored to it.
    private static let pillValueWidth: CGFloat = 48

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
        VStack(alignment: .leading, spacing: Space.three) {
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
        VStack(alignment: .leading, spacing: Space.one) {
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
            // The slider rides its own row. Hand-rolled, on purpose: the
            // native one draws its own blue track and dark knob on this
            // system and ignores tint, so it can never wear our accent or a
            // visible grabber. This one can.
            DurationSlider(
                value: value,
                range: range,
                step: step,
                label: "\(title) duration",
                valueText: readout(value: Int(value.wrappedValue), offText: offText)
            )
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

/// A chunky duration slider: accent fill, white grabber, step snapping.
/// Native Slider is one line, but it brings its own colors on this system.
private struct DurationSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    let valueText: String

    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - Self.knobDiameter, 1)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.controlFill)
                    .frame(height: Self.trackHeight)
                Capsule()
                    .fill(Color.widgetAccent)
                    .frame(width: Self.knobDiameter + travel * fraction, height: Self.trackHeight)
                Circle()
                    .fill(.white)
                    .shadow(color: .cardShadow, radius: 2, y: 1)
                    .frame(width: Self.knobDiameter, height: Self.knobDiameter)
                    .offset(x: travel * fraction)
                    .scaleEffect(isDragging && !reduceMotion ? 1.15 : 1)
                    .animation(.bouncy(duration: 0.3), value: isDragging)
            }
            .frame(height: Self.knobDiameter)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        value = snapped(
                            range.lowerBound + min(max(
                                (drag.location.x - Self.knobDiameter / 2) / travel, 0), 1)
                                * (range.upperBound - range.lowerBound)
                        )
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: Self.knobDiameter)
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = snapped(min(value + step, range.upperBound))
            case .decrement: value = snapped(max(value - step, range.lowerBound))
            @unknown default: break
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func snapped(_ raw: Double) -> Double {
        (raw / step).rounded() * step
    }

    private static let knobDiameter: CGFloat = 22
    private static let trackHeight: CGFloat = 8
}

/// One round media button: quiet circle until the pointer lands. Same size
/// and language everywhere, so the row never reflows as the timer moves.
private struct MediaButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: Self.diameter, height: Self.diameter)
                .background(Circle().fill(isHovered ? Color.controlFill : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { isHovered = $0 }
    }

    private static let diameter: CGFloat = 32
}

