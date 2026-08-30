// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import XCTest
@testable import CCPKit

extension XCTestCase {
    /// A store over a directory of its own, removed when the test ends. Each
    /// call gets a fresh one, so a test can say what is on disk by putting it
    /// there rather than by clearing up after the last test.
    func temporaryStore<Value>(
        default value: Value,
        filename: String = "layout.json"
    ) -> JSONFileStore<Value> {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ccp-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return JSONFileStore(filename: filename, default: value, in: directory)
    }
}

/// Writes `contents` where the store will look for its file.
func write(_ contents: String, forStore store: JSONFileStore<some Any>) throws {
    try FileManager.default.createDirectory(
        at: store.url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: store.url)
}
