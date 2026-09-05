// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation

/// One block as Craft echoes it back. Every write response carries the
/// canonical markdown and the assigned ids, which is what the sidecar is
/// built from — never what was sent, since a POST can split one sent block
/// into several.
public struct CraftBlock: Codable, Equatable, Sendable {
    public var id: String
    public var markdown: String

    public init(id: String, markdown: String) {
        self.id = id
        self.markdown = markdown
    }
}

extension CraftClient {
    // MARK: - Block writes

    private struct PutBody: Encodable {
        struct Item: Encodable {
            var id: String
            var markdown: String
        }
        var blocks: [Item]
    }

    private struct PostBody: Encodable {
        struct Item: Encodable {
            var type = "text"
            var markdown: String
        }
        struct Position: Encodable {
            var position: String
            var pageId: String?
            var siblingId: String?
        }
        var blocks: [Item]
        var position: Position
    }

    private struct DeleteBody: Encodable {
        var blockIds: [String]
    }

    private struct MoveBody: Encodable {
        var blockIds: [String]
        var position: PostBody.Position
    }

    private struct ItemsEnvelope: Decodable {
        var items: [CraftBlock]?
    }

    private struct BlocksEnvelope: Decodable {
        var blocks: [CraftBlock]?
    }

    private struct MovedEnvelope: Decodable {
        struct Item: Decodable {
            var id: String
        }
        var items: [Item]?
    }

    private struct MovedBlocksEnvelope: Decodable {
        struct Item: Decodable {
            var id: String
        }
        var blocks: [Item]?
    }

    /// The move echo carries ids only, never markdown — and in whatever
    /// envelope the server chose. Tolerated like the write echo: `items`,
    /// `blocks`, or a bare array. Nil when nothing parsed.
    static func decodeMovedIDs(from data: Data) -> [String]? {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(MovedEnvelope.self, from: data),
           let items = envelope.items {
            return items.map(\.id)
        }
        if let envelope = try? decoder.decode(MovedBlocksEnvelope.self, from: data),
           let items = envelope.blocks {
            return items.map(\.id)
        }
        if let items = try? decoder.decode([MovedEnvelope.Item].self, from: data) {
            return items.map(\.id)
        }
        return nil
    }

    /// Decode a write echo tolerantly: the documented shape is an `items`
    /// envelope, but a `blocks` envelope or bare array must not fail the
    /// whole push if that is what arrives.
    /// Items without both an id and markdown are skipped, never guessed at.
    static func decodeBlocks(from data: Data) -> [CraftBlock]? {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(ItemsEnvelope.self, from: data),
           let blocks = envelope.items {
            return blocks
        }
        if let envelope = try? decoder.decode(BlocksEnvelope.self, from: data),
           let blocks = envelope.blocks {
            return blocks
        }
        return try? decoder.decode([CraftBlock].self, from: data)
    }

    private func send(_ path: String, method: String, body: some Encodable) async throws(CraftClientError) -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw CraftClientError.unreachable(statusCode: nil)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CraftClientError.unreachable(statusCode: nil)
        }
        // 429 carries the shared budget state: honour Retry-After when the
        // server names one, so the next attempt lands inside the window.
        if http.statusCode == 429 {
            let header = http.value(forHTTPHeaderField: "Retry-After")
            throw CraftClientError.rateLimited(retryAfter: header.flatMap(TimeInterval.init))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CraftClientError.unreachable(statusCode: http.statusCode)
        }
        return (data, http)
    }

    /// `PUT /blocks` — changed slices over the ids the sidecar holds. Sends
    /// `{id, markdown}` only, so everything else on the block is untouched.
    /// Returns the echo: the canonical markdown per id.
    public func updateBlocks(_ updates: [BlockUpdate]) async throws(CraftClientError) -> [CraftBlock] {
        let body = PutBody(blocks: updates.map { PutBody.Item(id: $0.id, markdown: $0.markdown) })
        let (data, _) = try await send("blocks", method: "PUT", body: body)
        return Self.decodeBlocks(from: data) ?? []
    }

    /// `POST /blocks` — new slices, one batch, in plan order. One batch means
    /// one anchor: every insert must share it (the adapter groups by anchor
    /// and calls per group). The echo comes back in an `items` envelope in
    /// request order with assigned ids; a split (one slice becoming several
    /// blocks) shows up as extra items, which the sidecar rebuild pairs
    /// positionally.
    ///
    /// Assumed, to verify live: the server lays a shared-anchor batch down in
    /// array order after the anchor. A pasted run landing scrambled means
    /// chaining off returned ids instead.
    public func postBlocks(_ inserts: [BlockInsert], documentID: String, headSiblingID: String? = nil) async throws(CraftClientError) -> [CraftBlock] {
        let position: PostBody.Position
        if let anchor = inserts.compactMap(\.afterID).first {
            position = PostBody.Position(position: "after", pageId: nil, siblingId: anchor)
        } else if let head = headSiblingID {
            // Head of a non-empty document. Neither "start"+pageId nor
            // "before"+siblingId inserts above the first block — both merge
            // into it (observed live 2026-09-05), and pageId+siblingId
            // together 400 with invalid_union, so no single POST can address
            // the head. The batch lands at the end, where appends stay
            // separate and ordered, and is moved before the head — verified
            // live to arrive separate and in order, including multi-block
            // batches (ccp-gfe5).
            return try await postHead(inserts, documentID: documentID, headSiblingID: head)
        } else {
            // First sync into an empty document, where there is no head block
            // to address. Observed live to lay the batch down in order.
            position = PostBody.Position(position: "start", pageId: documentID, siblingId: nil)
        }
        let body = PostBody(blocks: inserts.map { PostBody.Item(markdown: $0.markdown) },
                            position: position)
        let (data, _) = try await send("blocks", method: "POST", body: body)
        let echo = Self.decodeBlocks(from: data) ?? []
        // A short echo is a protocol anomaly, not a partial success: splits
        // only ever ADD items, so fewer items than inserts means the response
        // cannot be attributed. Recording it would wire ids to the wrong
        // slices; fail instead and let the whole group retry.
        guard echo.count >= inserts.count else {
            throw CraftClientError.unreachable(statusCode: nil)
        }
        return echo
    }

    /// Head inserts ride two requests: POST at the end, then MOVE before the
    /// head. The POST echo carries the canonical markdown for the sidecar;
    /// the move echo carries ids only and must name back every posted id —
    /// a short or mismatched move echo leaves blocks at the end while the
    /// sidecar would claim the head, so it rolls back like a failure.
    ///
    /// A failed move rolls the posted blocks back with a best-effort DELETE,
    /// so a retry re-posts rather than orphaning a copy at the end — except
    /// on rate-limit, where another write answers backpressure with more
    /// pressure: the posted blocks stay, the limit's own retry re-posts, and
    /// the duplicate is visible to delete until the pull seed (ccp-2zi.6)
    /// heals order. If any rollback itself fails the orphans stay, and the
    /// retry will duplicate them — accepted: it needs two failures in a row.
    private func postHead(_ inserts: [BlockInsert], documentID: String,
                          headSiblingID: String) async throws(CraftClientError) -> [CraftBlock] {
        let body = PostBody(blocks: inserts.map { PostBody.Item(markdown: $0.markdown) },
                            position: PostBody.Position(position: "end", pageId: documentID,
                                                        siblingId: nil))
        let (data, _) = try await send("blocks", method: "POST", body: body)
        let echo = Self.decodeBlocks(from: data) ?? []
        guard echo.count >= inserts.count else {
            throw CraftClientError.unreachable(statusCode: nil)
        }
        let postedIDs = echo.map(\.id)
        do {
            let movedIDs = try await moveBlocks(postedIDs, before: headSiblingID)
            guard Set(movedIDs) == Set(postedIDs), movedIDs.count == postedIDs.count else {
                throw CraftClientError.unreachable(statusCode: nil)
            }
        } catch {
            // Typed throws guarantees CraftClientError; the fallback is
            // unreachable rather than a guess.
            let moveError = (error as? CraftClientError) ?? .unreachable(statusCode: nil)
            // Backpressure answers backpressure with nothing: another write
            // into a throttled window only spends budget.
            if case .rateLimited = moveError {
                throw moveError
            }
            try? await deleteBlocks(postedIDs)
            throw moveError
        }
        return echo
    }

    /// `PUT /blocks/move` — ids before a sibling. Returns the moved ids;
    /// the echo carries no markdown, so callers pair it by id only.
    public func moveBlocks(_ ids: [String], before siblingId: String) async throws(CraftClientError) -> [String] {
        let body = MoveBody(blockIds: ids,
                            position: PostBody.Position(position: "before", pageId: nil,
                                                        siblingId: siblingId))
        let (data, _) = try await send("blocks/move", method: "PUT", body: body)
        guard let movedIDs = Self.decodeMovedIDs(from: data) else {
            throw CraftClientError.unreachable(statusCode: nil)
        }
        return movedIDs
    }

    /// `DELETE /blocks` — ids the diff found missing. Never called for
    /// read-only entries; the diff pins those before this is reached.
    public func deleteBlocks(_ ids: [String]) async throws(CraftClientError) {
        let (_, _) = try await send("blocks", method: "DELETE", body: DeleteBody(blockIds: ids))
    }
}
