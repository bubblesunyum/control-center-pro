// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// One JSON dictionary under one UserDefaults key. Load failures read as
/// empty and never write — failed decodes are bytes we do not understand,
/// never bytes we may replace. Callers that need a rescue copy (the notes
/// document, the block-id sidecar) layer it on top.
struct DefaultsMap<Value: Codable> {
    let defaults: UserDefaults
    let key: String

    func load() -> [String: Value] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Value].self, from: data)
        else { return [:] }
        return decoded
    }

    /// True only when bytes are present but do not decode. A stored empty map
    /// decodes fine and is not corruption — whatever wrote it (including an
    /// older build's last-entry drop) meant empty.
    var hasUndecodableBytes: Bool {
        guard let data = defaults.data(forKey: key) else { return false }
        return (try? JSONDecoder().decode([String: Value].self, from: data)) == nil
    }

    /// False when there was nothing encodable — the key stays untouched.
    @discardableResult
    func save(_ map: [String: Value]) -> Bool {
        guard let data = try? JSONEncoder().encode(map) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    func set(_ value: Value?, for id: String) {
        var map = load()
        map[id] = value
        if map.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            save(map)
        }
    }
}
