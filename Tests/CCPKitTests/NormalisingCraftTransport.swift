// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
@testable import CCPKit

/// A fake Craft that answers from a document it actually keeps, and — the
/// point of it — **normalises markdown on write** the way the real one does
/// (`craft-normalises-markdown-on-write`, verified live 2026-09-04).
///
/// Every other fake in this suite echoes back exactly what was sent, so the
/// whole sync suite runs in the one case where our markdown and Craft's are
/// the same string. That is precisely the case in which a dialect bug cannot
/// appear, which is why 883 tests were quiet through ccp-c2x5.
final class NormalisingCraftTransport: CraftTransport, @unchecked Sendable {
    struct Block {
        var id: String
        var markdown: String
        /// A sub-page's own blocks. Craft addresses every block by id however
        /// deep it sits, which is what lets a stray anchor write the parent
        /// page's text into the sub-page (ccp-d8ec).
        var children: [Block] = []
    }

    /// The document, in order. Seed it to stand for a Craft doc that already
    /// holds text; leave it empty for a freshly provisioned one.
    var blocks: [Block] = []
    var title = "Note"
    /// Every request, for asserting a round wrote nothing.
    private(set) var requests: [(method: String, path: String)] = []
    /// True while Craft should respell; off reproduces the old echoing fake.
    var normalises = true
    /// Makes DELETE /blocks fail, for the half-applied-round cases.
    var failDelete = false
    /// Runs after a write is applied, for the races that happen in Craft
    /// while a round is away.
    var onWrite: (() -> Void)?

    private var nextID = 0

    init(blocks: [Block] = []) {
        self.blocks = blocks
    }

    /// Requests that changed the document — the assertion a quiet round needs.
    var writes: [(method: String, path: String)] {
        requests.filter { $0.method != "GET" }
    }

    /// The markdown each write request carried, in request order. What a
    /// round actually re-sent is the churn assertion; counting requests
    /// cannot see it, since a batch of one and a batch of three are both
    /// one PUT.
    var writtenMarkdown: [[String]] = []

    // MARK: - Craft's canonical form

    /// What Craft stores for a block of markdown: respelled, trimmed, and
    /// split where Craft splits. One sent block can become several.
    static func canonical(_ markdown: String) -> [String] {
        markdown
            .components(separatedBy: "\n\n")
            .map(respelled)
            .filter { !$0.isEmpty }
    }

    private static func respelled(_ markdown: String) -> String {
        var out = markdown
        // _italics_ -> *italics*, --- -> ***, trailing whitespace stripped.
        out = out.replacingOccurrences(of: "_([^_\n]+)_", with: "*$1*",
                                       options: .regularExpression)
        out = out.replacingOccurrences(of: "^---$", with: "***",
                                       options: [.regularExpression])
        return out.replacingOccurrences(of: "[ \t]+$", with: "",
                                        options: [.regularExpression])
    }

    private func stored(_ markdown: String) -> [String] {
        normalises ? Self.canonical(markdown) : [markdown]
    }

    private func mintID() -> String {
        nextID += 1
        return "craft-\(nextID)"
    }

    // MARK: - Transport

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let path = url.lastPathComponent
        let method = request.httpMethod ?? "GET"
        requests.append((method, path))
        let body = request.httpBody
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if failDelete, method == "DELETE" {
            return (Data("{}".utf8),
                    HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil,
                                    headerFields: nil)!)
        }
        if method != "GET", let sent = body["blocks"] as? [[String: Any]] {
            writtenMarkdown.append(sent.compactMap { $0["markdown"] as? String })
        }
        let payload = json(method: method, path: path, url: url, body: body)
        if method != "GET" { onWrite?() }
        return (Data(payload.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func json(method: String, path: String, url: URL, body: [String: Any]) -> String {
        switch (method, path) {
        case ("GET", "connection"):
            return #"{"space":{"name":"Test","id":"space1"},"utc":{"time":"2026-09-06T19:00:00Z"}}"#
        case ("GET", "documents"):
            return #"{"items":[]}"#
        case ("POST", "documents"):
            if let sent = (body["documents"] as? [[String: Any]])?.first,
               let name = sent["title"] as? String {
                title = name
            }
            return #"{"items":[{"id":"doc1","title":\#(quoted(title))}]}"#
        case ("GET", "blocks"):
            return page()
        case ("PUT", "blocks"):
            return put(body)
        case ("POST", "blocks"):
            return post(body)
        case ("DELETE", "blocks"):
            return delete(body)
        case (_, "move"):
            return move(body)
        default:
            return "{}"
        }
    }

    private func page() -> String {
        #"{"id":"doc1","type":"page","markdown":\#(quoted(title)),"content":[\#(rendered(blocks))]}"#
    }

    private func rendered(_ list: [Block]) -> String {
        list.map { block in
            block.children.isEmpty
                ? #"{"id":"\#(block.id)","type":"text","markdown":\#(quoted(block.markdown))}"#
                : #"{"id":"\#(block.id)","type":"page","markdown":\#(quoted(block.markdown)),"content":[\#(rendered(block.children))]}"#
        }.joined(separator: ",")
    }

    /// Reach a block by id wherever it sits, and hand its owning list to the
    /// caller. Nil when no such id exists anywhere in the document.
    private func withBlock<T>(_ id: String, _ body: (inout [Block], Int) -> T) -> T? {
        func search(_ list: inout [Block]) -> T? {
            if let index = list.firstIndex(where: { $0.id == id }) { return body(&list, index) }
            for index in list.indices {
                if let hit = search(&list[index].children) { return hit }
            }
            return nil
        }
        return search(&blocks)
    }

    private func put(_ body: [String: Any]) -> String {
        var echo: [Block] = []
        for item in body["blocks"] as? [[String: Any]] ?? [] {
            guard let id = item["id"] as? String,
                  let markdown = item["markdown"] as? String else { continue }
            // The page root is the title, not a block (craft-rename-is-page-id-put-blocks).
            if id == "doc1" {
                title = markdown
                echo.append(Block(id: id, markdown: markdown))
                continue
            }
            let forms = stored(markdown)
            guard let first = forms.first else { continue }
            // A split keeps the id on the first piece; the rest are new
            // blocks landing right behind it.
            let extras = forms.dropFirst().map { Block(id: mintID(), markdown: $0) }
            let written = withBlock(id) { list, index -> [Block] in
                list[index].markdown = first
                list.insert(contentsOf: extras, at: index + 1)
                return [list[index]] + extras
            }
            echo.append(contentsOf: written ?? [])
        }
        return items(echo)
    }

    private func post(_ body: [String: Any]) -> String {
        var echo: [Block] = []
        for item in body["blocks"] as? [[String: Any]] ?? [] {
            guard let markdown = item["markdown"] as? String else { continue }
            echo += stored(markdown).map { Block(id: mintID(), markdown: $0) }
        }
        let position = body["position"] as? [String: Any] ?? [:]
        // "after" names a sibling, and the sibling decides which list the
        // batch lands in — the sub-page's own, when the id sits inside one.
        if position["position"] as? String == "after",
           let sibling = position["siblingId"] as? String,
           withBlock(sibling, { list, index in list.insert(contentsOf: echo, at: index + 1) }) != nil {
            return items(echo)
        }
        blocks.insert(contentsOf: echo,
                      at: position["position"] as? String == "start" ? 0 : blocks.count)
        return items(echo)
    }

    private func delete(_ body: [String: Any]) -> String {
        let ids = Set(body["blockIds"] as? [String] ?? [])
        func prune(_ list: inout [Block]) {
            list.removeAll { ids.contains($0.id) }
            for index in list.indices { prune(&list[index].children) }
        }
        prune(&blocks)
        return #"{"items":[]}"#
    }

    private func move(_ body: [String: Any]) -> String {
        let ids = Set(body["blockIds"] as? [String] ?? [])
        var moved: [Block] = []
        func take(_ list: inout [Block]) {
            moved += list.filter { ids.contains($0.id) }
            list.removeAll { ids.contains($0.id) }
            for index in list.indices { take(&list[index].children) }
        }
        take(&blocks)
        let position = body["position"] as? [String: Any] ?? [:]
        let after = position["position"] as? String == "after"
        let landed = (position["siblingId"] as? String).flatMap { sibling in
            withBlock(sibling) { list, index in
                list.insert(contentsOf: moved, at: after ? index + 1 : index)
            }
        }
        if landed == nil { blocks.insert(contentsOf: moved, at: 0) }
        return items(moved)
    }

    private func items(_ echo: [Block]) -> String {
        let body = echo.map {
            #"{"id":"\#($0.id)","markdown":\#(quoted($0.markdown))}"#
        }.joined(separator: ",")
        return #"{"items":[\#(body)]}"#
    }

    private func quoted(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text])
        let array = String(data: data, encoding: .utf8)!
        return String(array.dropFirst().dropLast())
    }
}
