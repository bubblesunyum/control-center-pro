// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// Atomic, owner-only file write behind the credential stores.
///
/// Owner-only from birth, never world-readable in between: `.atomic`
/// renames a default-mode temp file into place and chmods after, which
/// leaves a 0644 window a crash makes permanent — so the temp file is
/// created 0600 and renamed over the target instead. A crash mid-swap
/// loses the credential (fail-safe: the user re-enters it) rather than
/// exposing it.
public enum OwnerOnlyFileWriter {
    public enum Error: Swift.Error {
        case unwritten
    }

    public static func write(_ data: Data, to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let tmp = directory.appendingPathComponent(UUID().uuidString)
        do {
            guard FileManager.default.createFile(atPath: tmp.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw Error.unwritten
            }
            try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}
