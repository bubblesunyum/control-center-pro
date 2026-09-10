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
    }

    /// The document, in order. Seed it to stand for a Craft doc that already
    /// holds text; leave it empty for a freshly provisioned one.
    var blocks: [Block] = []
    var title = "Note"
    /// Every request, for asserting a round wrote nothing.
    private(set) var requests: [(method: String, path: String)] = []
    /// True while Craft should respell; off reproduces the old echoing fake.
    var normalises = true

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
        if method != "GET", let sent = body["blocks"] as? [[String: Any]] {
            writtenMarkdown.append(sent.compactMap { $0["markdown"] as? String })
        }
        return (Data(json(method: method, path: path, url: url, body: body).utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func json(method: String, path: String, url: URL, body: [String: Any]) -> String {
        switch (method, path) {
        case ("GET", "connection"):
            return #"{"space":{"name":"Test","id":"space1"},"utc":{"time":"2026-09-06T19:00:00Z"}}"#
        case ("GET", "documents"):
            return #"{"items":[]}"#
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
        let content = blocks.map {
            #"{"id":"\#($0.id)","type":"text","markdown":\#(quoted($0.markdown))}"#
        }.joined(separator: ",")
        return #"{"id":"doc1","type":"page","markdown":\#(quoted(title)),"content":[\#(content)]}"#
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
            guard let index = blocks.firstIndex(where: { $0.id == id }) else { continue }
            let forms = stored(markdown)
            guard let first = forms.first else { continue }
            blocks[index].markdown = first
            echo.append(blocks[index])
            // A split keeps the id on the first piece; the rest are new
            // blocks landing right behind it.
            for extra in forms.dropFirst().reversed() {
                let new = Block(id: mintID(), markdown: extra)
                blocks.insert(new, at: index + 1)
                echo.append(new)
            }
        }
        return items(echo)
    }

    private func post(_ body: [String: Any]) -> String {
        let position = body["position"] as? [String: Any] ?? [:]
        var cursor: Int
        switch position["position"] as? String {
        case "after":
            let sibling = position["siblingId"] as? String
            cursor = (blocks.firstIndex { $0.id == sibling }).map { $0 + 1 } ?? blocks.count
        case "start":
            cursor = 0
        default:
            cursor = blocks.count
        }
        var echo: [Block] = []
        for item in body["blocks"] as? [[String: Any]] ?? [] {
            guard let markdown = item["markdown"] as? String else { continue }
            for form in stored(markdown) {
                let new = Block(id: mintID(), markdown: form)
                blocks.insert(new, at: cursor)
                cursor += 1
                echo.append(new)
            }
        }
        return items(echo)
    }

    private func delete(_ body: [String: Any]) -> String {
        let ids = Set(body["blockIds"] as? [String] ?? [])
        blocks.removeAll { ids.contains($0.id) }
        return #"{"items":[]}"#
    }

    private func move(_ body: [String: Any]) -> String {
        let ids = body["blockIds"] as? [String] ?? []
        let position = body["position"] as? [String: Any] ?? [:]
        let moved = blocks.filter { ids.contains($0.id) }
        blocks.removeAll { ids.contains($0.id) }
        let sibling = position["siblingId"] as? String
        let anchor = blocks.firstIndex { $0.id == sibling } ?? 0
        let target = (position["position"] as? String) == "after" ? anchor + 1 : anchor
        blocks.insert(contentsOf: moved, at: min(target, blocks.count))
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
