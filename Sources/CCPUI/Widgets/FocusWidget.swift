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
        size: .compact
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
    @State private var isTransportHovered = false
    @State private var isIntervalsHovered = false

    /// The phase's name — "Focus" or "Focus Break". The card wears no
    /// header, so this never draws; VoiceOver and the crown badge read it.
    /// A derived copy of the static descriptor: identity and icon stay
    /// intrinsic, only the title follows the clock.
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
        // No header — the card is just the transport. WidgetCard's inset
        // and centring, without its title row.
        GlassCard {
            VStack(alignment: .leading, spacing: Space.one) {
                mainRow
                if store.notificationStatus == .denied {
                    notificationGrantRow
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            // Roomier than the 12pt card standard: 1.5x, so the ring and its
            // crown badge get air.
            .padding(Space.oneHalf * 1.5)
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

    /// The transport: pause/play rides bare in the ring's center. Beside
    /// the ring, one column holds the countdown centered with reset and
    /// skip in a row, and the intervals pill underneath it. One arrangement
    /// in every state, so the row never reflows.
    private var mainRow: some View {
        HStack(spacing: Space.two) {
            ZStack {
                ProgressRing(
                    fraction: progressFraction,
                    tint: progressTint,
                    isBreathing: store.isRunning
                )
                // Glyph on empty glass with the ring as its target; the hover
                // chip is a circle inset to clear the track. Adaptive
                // primary, white in dark and black in light, since a fixed
                // white vanishes on light glass.
                Button(action: centerAction) {
                    Image(systemName: centerIcon)
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.primary)
                        .frame(width: Self.transportDiameter, height: Self.transportDiameter)
                        .background(Circle().fill(isTransportHovered ? Color.controlFill : Color.clear))
                        .frame(width: Self.ringDiameter, height: Self.ringDiameter)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(centerLabel)
                .onHover { isTransportHovered = $0 }
            }
            .frame(width: Self.ringDiameter, height: Self.ringDiameter)
            // The day's completed focuses ride the track's crown, over the
            // arc's meeting point: a top-hugging overlay plus a fixed rise
            // that plants the badge centre on the track. Hit-testing passes
            // through to the transport beneath.
            .overlay(alignment: .top) {
                // Always on, even at zero — the crown reads 0 until the
                // day's first round completes.
                RingCountBadge(count: store.completedFocusToday)
                    .offset(y: Self.crownNudge)
                    .allowsHitTesting(false)
            }
            // The pill tucks 6pt under the timer row, tighter than the card's
            // 8pt rhythm.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Space.two) {
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
                intervalPill
            }
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
    /// Hover chip behind the transport glyph: a circle that clears the
    /// track ringing it.
    private static let transportDiameter: CGFloat = 44
    /// Points the crown badge rises to centre on the track: its centre
    /// starts about half its height inside the ring, the crown sits ~3pt
    /// down from the edge.
    private static let crownNudge: CGFloat = -7

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

    /// The trailing transport, laid out in every state so the row never
    /// changes height as buttons come and go: reset while running or
    /// paused, skip while running. Absent buttons hold their frame
    /// invisibly — swapping in place, dead to hits and VoiceOver.
    private var controls: some View {
        HStack(spacing: Space.quarter) {
            MediaButton(systemImage: "arrow.counterclockwise", label: "Reset timer") {
                store.reset()
            }
            .visible(when: store.isRunning || store.isPaused)
            MediaButton(systemImage: "forward", label: "Skip this phase") {
                store.skip()
            }
            .visible(when: store.isRunning)
        }
    }

    private var nextTitle: String {
        switch store.pendingNext {
        case .shortBreak: "Start break"
        case .focus, nil: "Start focus"
        }
    }

    // MARK: - Durations

    /// Both intervals in one pill: tapping it opens the editor. A zero
    /// break reads as Off — that is the off switch.
    /// The live pill hugs its content — no fixed text widths. The popover
    /// still never moves: it anchors to the wrapper, which is sized by a
    /// hidden widest-case twin ("120 min" / "30 min") so its frame is
    /// constant while the live pill breathes inside it, leading-aligned,
    /// so its leading edge stays flush with the countdown number above.
    /// Measuring beats a magic width — it tracks type size — and a stable
    /// frame beats a clever anchor: corner anchors shove a wide popover
    /// sideways, top anchors lay it over the pill.
    private var intervalPill: some View {
        ZStack(alignment: .leading) {
            pillCapsule(focusText: "120 min", breakText: "30 min")
                .hidden()
                .accessibilityHidden(true)
            Button { isDurationsEditorPresented = true } label: {
                pillCapsule(
                    focusText: "\(store.settings.focusMinutes) min",
                    breakText: store.settings.breaksEnabled
                        ? "\(store.settings.shortBreakMinutes) min" : "Off",
                    isHovered: isIntervalsHovered
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(intervalPillLabel)
            .onHover { isIntervalsHovered = $0 }
        }
        .popover(isPresented: $isDurationsEditorPresented, arrowEdge: .top) {
            FocusSettingsPopover(store: store)
        }
    }

    /// The pill's look, shared by the live pill and its hidden measuring
    /// twin — one layout, so the twin can never drift from what it sizes.
    /// Hovering brightens the icons in the shared quiet-until-hover
    /// language; the twin never hovers.
    private func pillCapsule(focusText: String, breakText: String, isHovered: Bool = false) -> some View {
        HStack(spacing: Space.one) {
            HStack(spacing: Space.half) {
                Image(systemName: "timer")
                Text(focusText)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            Circle()
                .fill(.tertiary)
                .frame(width: Self.pillSeparatorDiameter, height: Self.pillSeparatorDiameter)
            HStack(spacing: Space.half) {
                Image(systemName: "mug")
                Text(breakText)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(isHovered ? .primary : .secondary)
        .padding(.horizontal, Space.one)
        .padding(.vertical, Space.half)
        .background(Capsule().fill(Color.controlFill))
    }

    private var intervalPillLabel: String {
        let focus = "Focus length, \(store.settings.focusMinutes) minutes"
        let rest = store.settings.breaksEnabled
            ? "break length, \(store.settings.shortBreakMinutes) minutes"
            : "breaks off"
        return "\(focus), \(rest). Change durations."
    }

    private static let pillSeparatorDiameter: CGFloat = 3

    // MARK: - Progress

    /// Countdown, not fill-up: the ring starts full and drains as the
    /// stretch runs out. Idle and between phases read full — nothing has
    /// run down yet.
    private var progressFraction: Double {
        if store.activePhase != nil {
            return 1 - (store.fractionElapsed(at: store.now) ?? 0)
        }
        return 1
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
                presets: [15, 25, 54]
            )
            sliderRow(
                systemImage: "mug",
                title: "Break",
                value: sliderBinding(for: \.shortBreakMinutes),
                range: doubleRange(FocusSettings.shortBreakRange),
                step: 1,
                presets: [0, 5, 15],
                offText: "Off"
            )
            Divider()
            nudgeRow
        }
        .padding(Space.oneHalf)
        .frame(minWidth: Layout.shelfMenuWidth)
    }

    private func sliderBinding(for keyPath: WritableKeyPath<FocusSettings, Int>) -> Binding<Double> {
        Binding(
            get: { Double(store.settings[keyPath: keyPath]) },
            set: {
                var next = store.settings
                next[keyPath: keyPath] = Int($0.rounded())
                store.updateSettings(next)
            }
        )
    }

    private func doubleRange(_ range: ClosedRange<Int>) -> ClosedRange<Double> {
        Double(range.lowerBound)...Double(range.upperBound)
    }

    /// One suggestion after a finished focus, with its delay.
    private var nudgeRow: some View {
        VStack(alignment: .leading, spacing: Space.one) {
            HStack(spacing: Space.half) {
                Image(systemName: "bell.badge")
                    .foregroundStyle(.secondary)
                Text("Return nudge")
                Spacer(minLength: Space.one)
                Toggle("", isOn: nudgeEnabledBinding)
                    .labelsHidden()
                    .accessibilityLabel("Suggest a focus when back at your desk")
            }
            .font(.caption.weight(.medium))
            sliderRow(
                systemImage: "deskclock",
                title: "Wait",
                value: nudgeDelayBinding,
                range: doubleRange(FocusSettings.returnNudgeDelayRange),
                step: 1,
                presets: [5, 12, 30]
            )
            .disabled(!store.settings.returnNudgeEnabled)
            .opacity(store.settings.returnNudgeEnabled ? 1 : 0.4)
        }
    }

    private var nudgeEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.returnNudgeEnabled },
            set: {
                var next = store.settings
                next.returnNudgeEnabled = $0
                store.updateSettings(next)
            }
        )
    }

    private var nudgeDelayBinding: Binding<Double> {
        Binding(
            get: { Double(store.settings.returnNudgeMinutes) },
            set: {
                var next = store.settings
                next.returnNudgeMinutes = Int($0.rounded())
                store.updateSettings(next)
            }
        )
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
            // Bare slider: the row above already names it, and the native
            // label would print a second title beside the track.
            Slider(value: value, in: range, step: step) {
                EmptyView()
            }
            .accessibilityLabel("\(title) duration")
            .accessibilityValue(readout(value: Int(value.wrappedValue), offText: offText))
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

/// The day-count on the ring's crown: solid white with dark digits, so it
/// reads over the arc at any fraction. Deliberately not the header badges'
/// translucent wash.
private struct RingCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.black)
            .padding(.horizontal, Space.half)
            .padding(.vertical, Space.quarter / 2)
            .background(Capsule().fill(.white))
            .accessibilityLabel("\(count) in Focus today")
    }
}

/// Lays out but hides: keeps the frame while invisible, dead to hits,
/// keyboard focus and VoiceOver.
private extension View {
    func visible(when visible: Bool) -> some View {
        self
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .disabled(!visible)
    }
}

/// One transport button: quiet until the pointer lands, then the hover
/// chip every icon button wears. Same size and language everywhere, so
/// the row never reflows as the timer moves.
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
                .background(
                    RoundedRectangle(cornerRadius: Radius.sparkline, style: .continuous)
                        .fill(isHovered ? Color.controlFill : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .onHover { isHovered = $0 }
    }

    private static let diameter: CGFloat = 32
}

