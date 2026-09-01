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
    /// Pinned items sort to the front and survive Clear. Absent from shelves
    /// written before pinning existed, which is why the decoder is lenient.
    public var isPinned: Bool

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
        createdAt: Date = Date(),
        isPinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.filePath = filePath
        self.text = text
        self.urlString = urlString
        self.imageFileName = imageFileName
        self.createdAt = createdAt
        self.isPinned = isPinned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        urlString = try c.decodeIfPresent(String.self, forKey: .urlString)
        imageFileName = try c.decodeIfPresent(String.self, forKey: .imageFileName)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}
