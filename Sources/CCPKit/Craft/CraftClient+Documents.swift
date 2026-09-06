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

    /// `PUT /blocks` over the page id — the page root IS the document title,
    /// and the block-update shape renames it (verified live 2026-09-06,
    /// ccp-o2dh: create, page-id PUT, re-fetch, delete). Returns the echo's
    /// canonical markdown, which is what the title baseline records — never
    /// what was sent, by the same fixed-point rule as the block sidecar.
    public func updateDocumentTitle(id: String, title: String) async throws(CraftClientError) -> CraftBlock {
        let echo = try await updateBlocks([BlockUpdate(id: id, markdown: title)])
        guard let first = echo.first else {
            throw CraftClientError.unreachable(statusCode: nil)
        }
        return first
    }

    /// `GET /documents?location=trash` — the ids of soft-deleted documents.
    /// The pull's gone-signal: a trashed doc still answers `GET /blocks`
    /// with 200 and its full content (probed live 2026-09-06, ccp-5fom), so
    /// the fetch can never tell a deleted doc from a live one — only trash
    /// membership can. Transport failures throw so callers skip the pass;
    /// an undecodable body reads as naming nothing. Either way nothing
    /// deletes without positive membership.
    public func trashedDocumentIDs() async throws(CraftClientError) -> Set<String> {
        var components = URLComponents(url: baseURL.appending(path: "documents"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "location", value: "trash")]
        guard let url = components?.url else {
            throw CraftClientError.unreachable(statusCode: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, http) = try await send(request)
        // Undecodable reads as failure, never as empty: an empty trash and
        // an unreadable one must not conflate, or deletes silently stop
        // working while pushes green-light blind writes.
        guard let documents = Self.decodeDocuments(from: data) else {
            throw CraftClientError.unreachable(statusCode: http.statusCode)
        }
        return Set(documents.map(\.id))
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
