// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import WebKit

/// Cookies out of Zen (a Firefox fork) into the panel's shared web session.
///
/// Zen keeps first-party logins in `cookies.sqlite` (`moz_cookies`) inside
/// each `~/Library/Application Support/zen/Profiles/*/`. The panel's
/// `WKWebsiteDataStore.default()` is a separate jar, so a signed-in Zen is
/// signed out here until these are copied over. One import copies every live
/// cookie — persistent and session alike — from every profile; last write
/// wins on collisions.
///
/// Read-only on Zen's side: the database plus its WAL are copied to temp
/// files first so a running Zen never blocks the read and Zen itself is
/// untouched. Setting `HttpOnly` is not possible through
/// `HTTPCookiePropertyKey`, so imported cookies are network-identical but
/// JS-readable — fine for restoring logins, worth knowing for the paranoid.
public enum ZenCookieImport {
    /// Copy Zen's live cookies into `store`. Returns how many were set.
    /// Never throws: a missing Zen install, a locked database, or an empty
    /// jar is just zero, not an error — the caller reloads only when > 0.
    /// The read runs off the main actor (it spawns `sqlite3` per profile);
    /// only the jar writes hop onto it.
    @MainActor
    public static func importFromZen(
        into store: WKWebsiteDataStore = .default()
    ) async -> Int {
        let rows = await Task.detached(priority: .utility) { readZenCookies() }.value
        let now = Date().timeIntervalSince1970
        var imported = 0
        for row in rows {
            guard let cookie = row.httpCookie(now: now) else { continue }
            await setCookie(cookie, in: store)
            imported += 1
        }
        return imported
    }

    // MARK: - Reading Zen

    struct ZenCookieRow: Decodable, Sendable {
        var host: String
        var name: String
        var value: String
        var path: String?
        var expiry: Double
        var isSecure: Int

        /// A cookie the web jar will accept, or nil when expired or malformed.
        /// Firefox marks session cookies with `expiry == 0` — dropping those
        /// would miss exactly the logins kept in memory, so they import
        /// without an expiry. Leading-dot domains are Firefox's "send to
        /// subdomains" marker — the jar wants the bare domain.
        func httpCookie(now: Double) -> HTTPCookie? {
            guard !host.isEmpty, !name.isEmpty else { return nil }
            let domain = host.hasPrefix(".") ? String(host.dropFirst()) : host
            guard !domain.isEmpty else { return nil }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: domain,
                .path: (path?.isEmpty ?? true) ? "/" : path!,
                .name: name,
                .value: value,
                .version: "0",
            ]
            if expiry > 0 {
                guard expiry > now else { return nil }
                properties[.expires] = Date(timeIntervalSince1970: expiry)
            }
            if isSecure != 0 { properties[.secure] = "TRUE" }
            return HTTPCookie(properties: properties)
        }
    }

    static func zenCookieFiles() -> [URL] {
        let profiles = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/zen/Profiles", directoryHint: .isDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: profiles, includingPropertiesForKeys: nil)
        else { return [] }
        return entries
            .map { $0.appending(path: "cookies.sqlite") }
            .filter { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    nonisolated static func readZenCookies() -> [ZenCookieRow] {
        zenCookieFiles().flatMap { readCookieFile($0) }
    }

    private nonisolated static func readCookieFile(_ db: URL) -> [ZenCookieRow] {
        // Copy the database plus its WAL aside so a running Zen neither blocks
        // the read nor gets written to. The temp copies are removed after.
        // A cookie still only in shared memory without a WAL copy reads as
        // the last checkpoint — missing at worst, never corrupt.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ccp-zen-cookies-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let src = URL(fileURLWithPath: db.path + suffix)
                if FileManager.default.isReadableFile(atPath: src.path) {
                    try? FileManager.default.copyItem(at: src, to: dir.appending(path: "cookies.sqlite" + suffix))
                }
            }
        } catch {
            return []
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let json = queryWithSQLite3CLI(db: dir.appending(path: "cookies.sqlite")) else { return [] }
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ZenCookieRow].self, from: data)) ?? []
    }

    private nonisolated static func queryWithSQLite3CLI(db: URL) -> String? {
        let bin = "/usr/bin/sqlite3"
        guard FileManager.default.isExecutableFile(atPath: bin) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = [
            "--readonly", "--json", db.path,
            "SELECT host, name, value, path, expiry, isSecure FROM moz_cookies;",
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

    // MARK: - Writing the web jar

    private static func setCookie(_ cookie: HTTPCookie, in store: WKWebsiteDataStore) async {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.setCookie(cookie) {
                continuation.resume()
            }
        }
    }
}
