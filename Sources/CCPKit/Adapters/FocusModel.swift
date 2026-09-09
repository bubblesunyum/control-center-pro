// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Which kind of stretch the clock is measuring. Idle and paused are not
/// phases — they are the absence of one, tracked beside the phase.
///
/// There used to be a long break; now there is one break. The custom decoding
/// keeps that past readable: a stored `longBreak` lands as a break rather
/// than failing the whole file.
public enum FocusPhase: String, Codable, Sendable, CaseIterable {
    case focus
    case shortBreak

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "focus": self = .focus
        case "longBreak": self = .shortBreak
        default: self = .shortBreak
        }
    }
}

public extension FocusPhase {
    var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Break"
        }
    }

    /// Whether this phase is a rest one. Today there is only one.
    var isBreak: Bool { self != .focus }
}

/// Durations, plain data — the store owns what the numbers mean.
///
/// The ranges are the editors' ranges too, so clamping and the UI can never
/// disagree about what a legal duration is. A zero break means no breaks:
/// dragging break to zero turns them off rather than needing a switch.
/// Decoding tolerates the removed keys: an old file still reads, leftovers
/// are ignored, and a file saved with the old breaks switch off lands at
/// zero so it stays off.
public struct FocusSettings: Codable, Sendable, Hashable {
    public static let focusRange = 5...120
    public static let shortBreakRange = 0...30

    public var focusMinutes: Int
    public var shortBreakMinutes: Int

    /// Breaks are on whenever a break has a length. Zero is the off switch.
    public var breaksEnabled: Bool { shortBreakMinutes > 0 }

    public static let `default` = FocusSettings(
        focusMinutes: 25,
        shortBreakMinutes: 5
    )

    public init(
        focusMinutes: Int,
        shortBreakMinutes: Int
    ) {
        self.focusMinutes = focusMinutes
        self.shortBreakMinutes = shortBreakMinutes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.focusMinutes = try container.decodeIfPresent(Int.self, forKey: .focusMinutes)
            ?? Self.default.focusMinutes
        self.shortBreakMinutes = try container.decodeIfPresent(Int.self, forKey: .shortBreakMinutes)
            ?? Self.default.shortBreakMinutes
        // The old switch, honoured once: off with a nonzero length means zero.
        if try container.decodeIfPresent(Bool.self, forKey: .breaksEnabled) == false,
           shortBreakMinutes > 0
        {
            self.shortBreakMinutes = 0
        }
    }

    enum CodingKeys: String, CodingKey {
        case focusMinutes
        case shortBreakMinutes
        case breaksEnabled
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(focusMinutes, forKey: .focusMinutes)
        try container.encode(shortBreakMinutes, forKey: .shortBreakMinutes)
        // Derived, but still written: a reader from before the migration
        // learns off-ness from this key rather than from the zero.
        try container.encode(breaksEnabled, forKey: .breaksEnabled)
    }

    public var clamped: FocusSettings {
        FocusSettings(
            focusMinutes: focusMinutes.clamped(to: Self.focusRange),
            shortBreakMinutes: shortBreakMinutes.clamped(to: Self.shortBreakRange)
        )
    }

    public func minutes(for phase: FocusPhase) -> Int {
        switch phase {
        case .focus: focusMinutes
        case .shortBreak: shortBreakMinutes
        }
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// One run of one phase. Written when the phase exits — completed when it ran
/// to its deadline, abandoned when skipped or reset.
public struct FocusSession: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var kind: FocusPhase
    public var startedAt: Date
    public var endedAt: Date?
    public var completed: Bool

    public init(
        id: UUID = UUID(),
        kind: FocusPhase,
        startedAt: Date,
        endedAt: Date? = nil,
        completed: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.completed = completed
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case startedAt
        case endedAt
        case completed
    }
}

/// Everything the store persists. A running phase is a phase plus a deadline,
/// so quitting mid-focus restores mid-focus rather than losing it.
struct FocusPersisted: Codable, Sendable {
    var settings: FocusSettings
    var sessions: [FocusSession]
    var activePhase: FocusPhase?
    var endsAt: Date?
    var pausedRemaining: TimeInterval?
    var pendingNext: FocusPhase?
    var focusStreak: Int
    var openSessionID: UUID?

    static let empty = FocusPersisted(
        settings: .default,
        sessions: [],
        activePhase: nil,
        endsAt: nil,
        pausedRemaining: nil,
        pendingNext: nil,
        focusStreak: 0,
        openSessionID: nil
    )

    enum CodingKeys: String, CodingKey {
        case settings
        case sessions
        case activePhase
        case endsAt
        case pausedRemaining
        case pendingNext
        case focusStreak
        case openSessionID
    }
}

// MARK: - Clock

/// Where the time comes from. The seam a test stands a stopped clock in for.
public protocol FocusClock: Sendable {
    func now() -> Date
}

public struct SystemFocusClock: FocusClock {
    public init() {}
    public func now() -> Date { Date() }
}
