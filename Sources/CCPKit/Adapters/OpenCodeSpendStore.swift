// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import SQLite3

// MARK: - Windowed spend

/// Dollar spend per quota window, from OpenCode's own session ledger.
///
/// The quota endpoint truncates `percent` to an int while the dashboard shows
/// spend-over-limit to a decimal — the same dollars the CLI records per
/// session — so the widget's decimals come from here. The endpoint stays
/// authoritative for resets and rate-limit status, and when this read fails
/// for any reason (missing file, lock, a schema rename upstream) the adapter
/// falls back to the endpoint's ints rather than showing nothing.
public struct OpenCodeSpendWindows: Sendable, Equatable {
    public var rolling: Double
    public var weekly: Double
    public var monthly: Double

    public init(rolling: Double, weekly: Double, monthly: Double) {
        self.rolling = rolling
        self.weekly = weekly
        self.monthly = monthly
    }
}

/// Where windowed spend comes from. The seam a test stands a fake in for:
/// the real one needs OpenCode's live database on disk.
public protocol OpenCodeSpendStore: Sendable {
    func spend(since starts: OpenCodeWindowStarts) async throws -> OpenCodeSpendWindows
}

/// One quota window's definition: how far back its spend reaches and what
/// spend it is measured against. Limits are the Go plan's dollar caps
/// (https://opencode.ai/docs/go); the window lengths mirror the endpoint's
/// own reset cadence.
public enum OpenCodeUsageWindowDef: CaseIterable {
    case rolling
    case weekly
    case monthly

    /// How far back the window reaches from its reset.
    public var length: TimeInterval {
        switch self {
        case .rolling: return 5 * 3600
        case .weekly: return 7 * 86400
        case .monthly: return 30 * 86400
        }
    }

    public var limitDollars: Double {
        switch self {
        case .rolling: return 12
        case .weekly: return 30
        case .monthly: return 60
        }
    }
}

/// When each window starts, derived from the endpoint's reset times: a window
/// is the `length` before its reset. Without a reset (offline, first run)
/// each window falls back to trailing length — except weekly, whose resets
/// land on Monday 00:00 UTC, so the calendar answers directly.
public struct OpenCodeWindowStarts: Sendable, Equatable {
    public var rolling: Date
    public var weekly: Date
    public var monthly: Date

    public init(rolling: Date, weekly: Date, monthly: Date) {
        self.rolling = rolling
        self.weekly = weekly
        self.monthly = monthly
    }

    public static func from(
        resets: (rolling: Date?, weekly: Date?, monthly: Date?),
        now: Date,
        calendar: Calendar = .utcGregorian
    ) -> OpenCodeWindowStarts {
        OpenCodeWindowStarts(
            rolling: resets.rolling?.addingTimeInterval(-OpenCodeUsageWindowDef.rolling.length)
                ?? now.addingTimeInterval(-OpenCodeUsageWindowDef.rolling.length),
            weekly: resets.weekly?.addingTimeInterval(-OpenCodeUsageWindowDef.weekly.length)
                ?? calendar.mostRecentMondayStart(beforeOrAt: now),
            monthly: resets.monthly?.addingTimeInterval(-OpenCodeUsageWindowDef.monthly.length)
                ?? now.addingTimeInterval(-OpenCodeUsageWindowDef.monthly.length)
        )
    }
}

public extension Calendar {
    static var utcGregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Monday 00:00 UTC on or before the given moment.
    func mostRecentMondayStart(beforeOrAt date: Date) -> Date {
        let weekday = component(.weekday, from: date) // 1 Sunday … 7 Saturday
        let daysSinceMonday = (weekday + 5) % 7
        let startOfDay = startOfDay(for: date)
        return self.date(byAdding: .day, value: -daysSinceMonday, to: startOfDay)!
    }
}

/// Reads `session.cost` from OpenCode's SQLite ledger without touching it:
///
/// - read-only open, so a bug here cannot corrupt the ledger;
/// - one bounded query over the small `session` table — the gigabyte-sized
///   transcript blobs in `part` are never read;
/// - off the caller's actor (detached), so a slow disk never stalls main.
public struct SQLiteOpenCodeSpendStore: OpenCodeSpendStore {
    private let dbFile: URL

    public init(
        dbFile: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/share/opencode/opencode.db")
    ) {
        self.dbFile = dbFile
    }

    public func spend(since starts: OpenCodeWindowStarts) async throws -> OpenCodeSpendWindows {
        try await Task.detached(priority: .utility) {
            try Self.query(dbFile: self.dbFile, starts: starts)
        }.value
    }

    static func query(dbFile: URL, starts: OpenCodeWindowStarts) throws -> OpenCodeSpendWindows {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            dbFile.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
            let db = handle
        else {
            sqlite3_close(handle)
            throw OpenCodeSpendError.unreadable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        let sql = """
            SELECT
                COALESCE(SUM(CASE WHEN time_updated >= ?1 THEN cost END), 0),
                COALESCE(SUM(CASE WHEN time_updated >= ?2 THEN cost END), 0),
                COALESCE(SUM(CASE WHEN time_updated >= ?3 THEN cost END), 0)
            FROM session
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let query = statement
        else { throw OpenCodeSpendError.unreadable }
        defer { sqlite3_finalize(query) }

        // `time_updated` is milliseconds since epoch; a schema rename turns
        // these binds into an error, which the adapter reads as "fall back".
        sqlite3_bind_int64(query, 1, Int64(starts.rolling.timeIntervalSince1970 * 1000))
        sqlite3_bind_int64(query, 2, Int64(starts.weekly.timeIntervalSince1970 * 1000))
        sqlite3_bind_int64(query, 3, Int64(starts.monthly.timeIntervalSince1970 * 1000))
        guard sqlite3_step(query) == SQLITE_ROW else { throw OpenCodeSpendError.unreadable }

        return OpenCodeSpendWindows(
            rolling: sqlite3_column_double(query, 0),
            weekly: sqlite3_column_double(query, 1),
            monthly: sqlite3_column_double(query, 2)
        )
    }
}

public enum OpenCodeSpendError: Sendable, Equatable, Error {
    /// Missing file, lock, or a schema this query no longer matches.
    case unreadable
}
