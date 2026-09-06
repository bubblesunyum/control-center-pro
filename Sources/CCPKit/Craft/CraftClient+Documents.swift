// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// One document as the create echo returns it. Titles may be empty strings;
/// a missing title decodes as one rather than failing the call. Extra keys
/// (the echo carries a `clickableLink`) are ignored.
public struct CraftDocument: Codable, Equatable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String = "") {
        self.id = id
        self.title = title
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
    }
}

extension CraftClient {
    // MARK: - Document creates

    private struct CreateDocumentBody: Encodable {
        struct Item: Encodable {
            var title: String
        }
        var documents: [Item]
    }

    /// `POST /documents` — one document, created EMPTY in `unsorted`.
    /// Content is a separate `POST /blocks`; a document id is its root block
    /// id, so the push can post at `start`+pageId into a fresh document with
    /// no head block to merge into. Returns the assigned id.
    public func createDocument(title: String) async throws(CraftClientError) -> CraftDocument {
        let body = CreateDocumentBody(documents: [CreateDocumentBody.Item(title: title)])
        let (data, _) = try await send("documents", method: "POST", body: body)
        guard let first = Self.decodeDocuments(from: data)?.first else {
            throw CraftClientError.unreachable(statusCode: nil)
        }
        return first
    }

    private struct DocumentItemsEnvelope: Decodable {
        var items: [CraftDocument]?
    }

    private static func decodeDocuments(from data: Data) -> [CraftDocument]? {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(DocumentItemsEnvelope.self, from: data),
           let items = envelope.items {
            return items
        }
        return try? decoder.decode([CraftDocument].self, from: data)
    }
}
