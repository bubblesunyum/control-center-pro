// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// One thing on the shelf: a file, a snippet of text, a link, or an image.
///
/// Persisted as JSON in Application Support; image payloads live alongside
/// clipboard images in Application Support/ShelfFiles. The model is deliberately
/// plain data — icons and thumbnails are derived in the view, not stored — so
/// a layout survives an app update that changes how a tile looks.
public struct ShelfItem: Identifiable, Codable, Equatable, Sendable, Hashable {
    public let id: UUID
    public let kind: Kind
    public let title: String
    /// For `.file`: absolute path of the original file at drop time. Shelf does
    /// not copy the file; it keeps a bookmark to heal moves where possible.
    public let filePath: String?
    public let text: String?
    public let urlString: String?
    /// For `.image` pastes: filename under ShelfFiles, relative rather than
    /// absolute so the store survives a home-directory move.
    public let imageFileName: String?
    public let createdAt: Date

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case file
        case text
        case link
        case image

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            self = Kind(rawValue: raw) ?? .file
        }
    }

    public init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        filePath: String? = nil,
        text: String? = nil,
        urlString: String? = nil,
        imageFileName: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.filePath = filePath
        self.text = text
        self.urlString = urlString
        self.imageFileName = imageFileName
        self.createdAt = createdAt
    }


}
