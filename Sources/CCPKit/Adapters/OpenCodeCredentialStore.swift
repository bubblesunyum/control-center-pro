// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Where the Go API key comes from.
///
/// V2 keeps credentials in `opencode.db` (SQLite, `credential` table) —
/// `~/.local/share/opencode/auth.json` is the legacy V1 file OpenCode no
/// longer writes, so it goes stale after a reconnect and must only be a
/// fallback. CCP reads the key, never asks for it, and never writes it
/// anywhere.
public protocol OpenCodeCredentialStore: Sendable {
    func loadAPIKey() throws -> String?
}

/// The `{"key":…}` extraction both on-disk stores share.
func extractOpenCodeAPIKey(from json: [String: Any]) -> String? {
    guard let key = json["key"] as? String, !key.isEmpty else { return nil }
    return key
}

/// Reads the key OpenCode saved. Throws nothing on a missing or unparsable
/// file — that is just "not connected", which the widget shows inline.
public struct FileOpenCodeCredentialStore: OpenCodeCredentialStore {
    private let authFile: URL

    public init(
        authFile: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/share/opencode/auth.json")
    ) {
        self.authFile = authFile
    }

    public func loadAPIKey() throws -> String? {
        guard let data = try? Data(contentsOf: authFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = json["opencode-go"] as? [String: Any]
        else { return nil }
        return extractOpenCodeAPIKey(from: entry)
    }
}

/// Reads the active `opencode-go` key from OpenCode's SQLite database.
///
/// The `credential.value` column holds JSON like `{"type":…,"key":…}`; the
/// active row wins, newest first, so a reconnected login beats a stale one.
/// Read-only — the widget never writes the database. A missing binary,
/// missing file, or unparsable row is just "not connected here", never an
/// error.
public struct DatabaseOpenCodeCredentialStore: OpenCodeCredentialStore {
    private let dbFile: URL?
    private let readCredentialRow: @Sendable (URL) -> String?

    public init(
        dbFile: URL? = nil,
        readCredentialRow: @escaping @Sendable (URL) -> String? = queryWithSQLite3CLI(db:)
    ) {
        self.dbFile = dbFile
        self.readCredentialRow = readCredentialRow
    }

    public func loadAPIKey() throws -> String? {
        let db = dbFile ?? Self.resolveDatabaseURL()
        guard let row = readCredentialRow(db),
              let data = row.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return extractOpenCodeAPIKey(from: json)
    }

    /// `OPENCODE_DB` wins, then `$XDG_DATA_HOME`, then the release default.
    static func resolveDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment["OPENCODE_DB"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appending(path: "opencode/opencode.db")
        }
        return home.appending(path: ".local/share/opencode/opencode.db")
    }

    public static func queryWithSQLite3CLI(db: URL) -> String? {
        let bin = "/usr/bin/sqlite3"
        guard FileManager.default.isExecutableFile(atPath: bin) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = [
            "--readonly", db.path,
            "SELECT value FROM credential WHERE integration_id='opencode-go' ORDER BY active DESC, rowid DESC LIMIT 1;",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let text = String(
            data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

/// Tries one store, then the other. The fetch path pairs the database with
/// the legacy file behind it.
public struct FallbackOpenCodeCredentialStore: OpenCodeCredentialStore {
    private let primary: any OpenCodeCredentialStore
    private let fallback: any OpenCodeCredentialStore

    public init(
        primary: any OpenCodeCredentialStore = DatabaseOpenCodeCredentialStore(),
        fallback: any OpenCodeCredentialStore = FileOpenCodeCredentialStore()
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    public func loadAPIKey() throws -> String? {
        if let key = try primary.loadAPIKey() { return key }
        return try fallback.loadAPIKey()
    }
}

/// In-memory stand-in for tests and previews. Never ships in the app.
public final class InMemoryOpenCodeCredentialStore: OpenCodeCredentialStore, @unchecked Sendable {
    private var key: String?

    public init(key: String? = nil) {
        self.key = key
    }

    public func loadAPIKey() throws -> String? { key }
}
