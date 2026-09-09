// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// A throwaway notes folder. UUID-scoped under /tmp, like the other
/// file-based tests; the OS reaps them, so tests never clean up after
/// themselves here.
func freshNotesDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ccp.notes.\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
