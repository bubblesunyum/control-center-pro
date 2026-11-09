// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import Foundation
import XCTest

@MainActor
final class WebsiteStoreTests: XCTestCase {
    private func freshDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(in directory: URL) -> WebsiteStore {
        let file: JSONFileStore<[WebsiteEntry]> = JSONFileStore(
            filename: "websites.json", default: [], in: directory)
        return WebsiteStore(file: file)
    }

    func testAddNormalizesAndPersistsRoundTrip() {
        let directory = freshDirectory()
        let store = makeStore(in: directory)

        let id = store.add(url: "  example.com ")

        XCTAssertTrue(id.rawValue.hasPrefix("website-"))
        let suffix = id.rawValue.dropFirst("website-".count)
        XCTAssertEqual(suffix.count, 8)
        XCTAssertTrue(suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(store.entry(for: id)?.url, "https://example.com")
        XCTAssertEqual(store.entry(for: id)?.originalURL, "https://example.com")

        let revived = makeStore(in: directory)
        XCTAssertEqual(revived.entry(for: id)?.url, "https://example.com")
        XCTAssertEqual(revived.entry(for: id)?.originalURL, "https://example.com")
    }

    func testAddKeepsAnExistingScheme() {
        let store = makeStore(in: freshDirectory())

        let plain = store.add(url: "http://example.com/a")
        let secure = store.add(url: "https://example.com/b")

        XCTAssertEqual(store.entry(for: plain)?.url, "http://example.com/a")
        XCTAssertEqual(store.entry(for: secure)?.url, "https://example.com/b")
    }

    func testUpdateResetRemoveRoundTrip() {
        let directory = freshDirectory()
        let store = makeStore(in: directory)
        let id = store.add(url: "example.com")

        store.updateURL(id, to: "other.com")
        XCTAssertEqual(store.entry(for: id)?.url, "https://other.com")
        XCTAssertEqual(makeStore(in: directory).entry(for: id)?.url, "https://other.com")

        store.resetToOriginal(id)
        XCTAssertEqual(store.entry(for: id)?.url, "https://example.com")
        XCTAssertEqual(makeStore(in: directory).entry(for: id)?.url, "https://example.com")

        store.remove(id)
        XCTAssertNil(store.entry(for: id))
        XCTAssertTrue(makeStore(in: directory).entries.isEmpty)
    }

    func testCodingKeysArePinned() throws {
        let literal = """
        {"id":"website-abcdef12","url":"https://example.com/","originalURL":"https://example.com/","lastReloadedAt":1234567890}
        """
        let decoded = try JSONDecoder().decode(WebsiteEntry.self, from: Data(literal.utf8))

        XCTAssertEqual(decoded.id, WidgetID("website-abcdef12"))
        XCTAssertEqual(decoded.url, "https://example.com/")
        XCTAssertEqual(decoded.originalURL, "https://example.com/")
        XCTAssertEqual(decoded.lastReloadedAt, Date(timeIntervalSinceReferenceDate: 1234567890))

        let data = try JSONEncoder().encode(decoded)
        let keyed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(keyed.keys.sorted(), ["id", "lastReloadedAt", "originalURL", "url"])
    }

    func testTolerantLoadSkipsABadEntry() throws {
        let directory = freshDirectory()
        let good = WebsiteEntry(
            id: WidgetID("website-abcdef12"),
            url: "https://example.com",
            originalURL: "https://example.com",
            lastReloadedAt: Date(timeIntervalSinceReferenceDate: 0))
        let goodJSON = String(data: try JSONEncoder().encode(good), encoding: .utf8)!
        let payload = "[\(goodJSON),{\"id\":42,\"url\":{}}]"
        try Data(payload.utf8).write(to: directory.appendingPathComponent("websites.json"))

        let store = makeStore(in: directory)

        XCTAssertEqual(store.entries.map(\.id), [WidgetID("website-abcdef12")])
    }

    func testShouldReloadBoundaries() {
        let store = makeStore(in: freshDirectory())
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let id = store.add(url: "example.com")
        store.markReloaded(id, at: base)

        XCTAssertFalse(store.shouldReload(id, at: base.addingTimeInterval(59 * 60)))
        XCTAssertTrue(store.shouldReload(id, at: base.addingTimeInterval(61 * 60)))
        XCTAssertFalse(store.shouldReload(WidgetID("website-missing"), at: base.addingTimeInterval(61 * 60)))
    }

    func testNormalizationIsDeterministic() {
        XCTAssertEqual(WebsiteStore.normalizedURL("  Example.com/a "), WebsiteStore.normalizedURL("  Example.com/a "))
        XCTAssertEqual(WebsiteStore.normalizedURL("example.com"), "https://example.com")
        XCTAssertEqual(WebsiteStore.normalizedURL("https://example.com"), "https://example.com")
        XCTAssertEqual(WebsiteStore.normalizedURL(""), "")
    }

    func testWidgetIDHelpers() {
        XCTAssertTrue(WidgetID("website").isWebsiteTemplate)
        XCTAssertFalse(WidgetID("website").isWebsiteInstance)
        XCTAssertTrue(WidgetID("website").isWebsite)

        XCTAssertFalse(WidgetID("website-abcdef12").isWebsiteTemplate)
        XCTAssertTrue(WidgetID("website-abcdef12").isWebsiteInstance)
        XCTAssertTrue(WidgetID("website-abcdef12").isWebsite)

        XCTAssertFalse(WidgetID("notes").isWebsite)
    }
}
