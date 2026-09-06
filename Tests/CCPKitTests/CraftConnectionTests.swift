// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import Foundation
import Security
import XCTest
@testable import CCPKit

/// The connection URL is the credential, so these are the tests that keep it
/// in an owner-only file and off the screen: validation, verification, and the one
/// rule that matters — a failed check changes nothing stored.
@MainActor
final class CraftConnectionTests: XCTestCase {
    // MARK: - Fakes

    private final class FakeTransport: CraftTransport, @unchecked Sendable {
        var result: Result<(Data, Int), Error>

        init(statusCode: Int, json: String) {
            result = .success((Data(json.utf8), statusCode))
        }

        init(error: Error) {
            result = .failure(error)
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            switch result {
            case .success(let data, let code):
                let response = HTTPURLResponse(url: request.url!,
                                               statusCode: code,
                                               httpVersion: nil,
                                               headerFields: nil)!
                return (data, response)
            case .failure(let error):
                throw error
            }
        }
    }

    private static let connectionJSON = """
        {"space":{"id":"a1","name":"My Space","timezone":"Europe/Berlin",
         "time":"2026-09-05T12:00:00","friendlyDate":"5 Sep"},
         "utc":{"time":"2026-09-05T10:00:00Z"},
         "urlTemplates":{"app":"craftdocs://open"}}
        """

    private func model(json: String = connectionJSON,
                       statusCode: Int = 200,
                       stored: URL? = nil) -> CraftConnectionModel {
        CraftConnectionModel(store: InMemoryCraftCredentialStore(url: stored),
                             transport: FakeTransport(statusCode: statusCode, json: json))
    }

    // MARK: - URL validation

    func testAcceptsAConnectionURLWithWhitespaceAndTrailingSlash() {
        let url = CraftClient.baseURL(
            from: "  https://connect.craft.do/links/abc123/api/v1/ \n")
        XCTAssertEqual(url?.absoluteString, "https://connect.craft.do/links/abc123/api/v1")
    }

    func testRejectsNonCraftHostsIncludingTheOtherCraftCompany() {
        XCTAssertNil(CraftClient.baseURL(from: "https://api.craft.co/v1"))
        XCTAssertNil(CraftClient.baseURL(from: "https://example.com/links/x/api/v1"))
    }

    func testRejectsNonHTTPSAndNonURLs() {
        XCTAssertNil(CraftClient.baseURL(from: "http://connect.craft.do/links/x/api/v1"))
        XCTAssertNil(CraftClient.baseURL(from: "not a url"))
        XCTAssertNil(CraftClient.baseURL(from: ""))
    }

    func testRejectsTheBareHostAndLookalikeHosts() {
        XCTAssertNil(CraftClient.baseURL(from: "https://connect.craft.do"),
                     "the bare host carries no credential")
        XCTAssertNil(CraftClient.baseURL(from: "https://connect.craft.do.evil.com/links/x"))
        XCTAssertNil(CraftClient.baseURL(from: "https://connect.craft.do@evil.com/links/x"))
    }

    // MARK: - Payload decoding

    func testDecodesTheSpaceNameAndServerClock() {
        let space = CraftClient.decodeSpace(from: Data(Self.connectionJSON.utf8))
        XCTAssertEqual(space?.name, "My Space")
        XCTAssertNotNil(space?.serverTime)
    }

    func testDecodesTheSpaceIDForDeepLinks() {
        let space = CraftClient.decodeSpace(from: Data(Self.connectionJSON.utf8))
        XCTAssertEqual(space?.spaceID, "a1")
    }

    func testDecodesAFractionalSecondClock() {
        let json = #"{"space":{"name":"S"},"utc":{"time":"2026-09-05T10:00:00.123Z"}}"#
        XCTAssertNotNil(CraftClient.decodeSpace(from: Data(json.utf8))?.serverTime)
    }

    func testAnUnparseableClockKeepsTheNameWithAnUnknownTime() {
        let json = #"{"space":{"name":"S"},"utc":{"time":"sometime"}}"#
        let space = CraftClient.decodeSpace(from: Data(json.utf8))
        XCTAssertEqual(space?.name, "S")
        XCTAssertNil(space?.serverTime, "an unknown clock must read as unknown, not as now")
    }

    func testRejectsAPayloadWithNoSpaceName() {
        XCTAssertNil(CraftClient.decodeSpace(from: Data(#"{"space":{}}"#.utf8)))
        XCTAssertNil(CraftClient.decodeSpace(from: Data("not json".utf8)))
    }

    // MARK: - Client

    func testNon2xxIsUnreachableWithItsStatus() async {
        let client = CraftClient(baseURL: URL(string: "https://connect.craft.do/x")!,
                                 transport: FakeTransport(statusCode: 401, json: "{}"))
        do {
            _ = try await client.checkConnection()
            XCTFail("a 401 must throw")
        } catch let error as CraftClientError {
            XCTAssertEqual(error, .unreachable(statusCode: 401))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testANetworkFailureIsUnreachableWithoutAStatus() async {
        let client = CraftClient(baseURL: URL(string: "https://connect.craft.do/x")!,
                                 transport: FakeTransport(error: URLError(.notConnectedToInternet)))
        do {
            _ = try await client.checkConnection()
            XCTFail("a dead network must throw")
        } catch let error as CraftClientError {
            XCTAssertEqual(error, .unreachable(statusCode: nil))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Model

    func testStartsUnconfiguredWithAnEmptyStore() {
        let model = model()
        XCTAssertEqual(model.status, .notConfigured)
        XCTAssertFalse(model.isConfigured)
        XCTAssertNil(model.baseURL)
    }

    func testStartsConfiguredWithoutNetworkWhenAURLIsStored() {
        let stored = URL(string: "https://connect.craft.do/links/x/api/v1")!
        let model = model(stored: stored)
        XCTAssertTrue(model.isConfigured)
        XCTAssertEqual(model.baseURL, stored)
        XCTAssertEqual(model.urlText, "", "the field must never echo the credential")
    }

    func testSavingGarbageMarksTheURLInvalidAndStoresNothing() {
        let model = model()
        model.urlText = "https://api.craft.co/v1"
        model.save()
        XCTAssertEqual(model.status, .invalidURL)
        XCTAssertFalse(model.isConfigured)
        XCTAssertNil(model.baseURL)
    }

    func testSavingAURLVerifiesItAndShowsTheSpace() async {
        let model = model()
        model.urlText = "https://connect.craft.do/links/x/api/v1"
        model.save()
        XCTAssertEqual(model.urlText, "", "the field clears on save whatever happens next")
        let deadline = Date().addingTimeInterval(2)
        while model.status != .connected(spaceName: "My Space"), Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(model.status, .connected(spaceName: "My Space"))
        XCTAssertTrue(model.isConfigured)
    }

    func testAFailedCheckKeepsTheStoredURL() async {
        let model = model(json: "{}", statusCode: 401)
        model.urlText = "https://connect.craft.do/links/x/api/v1"
        model.save()
        let deadline = Date().addingTimeInterval(2)
        while model.status != .unreachable, Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(model.status, .unreachable)
        XCTAssertNotNil(model.baseURL, "a failed check must not eat the credential")
    }

    func testForgettingClearsStoreAndStatus() {
        let stored = URL(string: "https://connect.craft.do/links/x/api/v1")!
        let model = model(stored: stored)
        model.forget()
        XCTAssertEqual(model.status, .notConfigured)
        XCTAssertFalse(model.isConfigured)
        XCTAssertNil(model.baseURL)
    }

    // MARK: - Keychain

    func testKeychainRoundTripsAndDeletes() throws {
        let store = KeychainCraftCredentialStore(
            service: "ccp.test.craft.\(UUID().uuidString)")
        XCTAssertNil(try store.loadConnectionURL())
        let url = URL(string: "https://connect.craft.do/links/x/api/v1")!
        try store.saveConnectionURL(url)
        XCTAssertEqual(try store.loadConnectionURL(), url)
        try store.saveConnectionURL(url)
        XCTAssertEqual(try store.loadConnectionURL(), url)
        try store.deleteConnectionURL()
        XCTAssertNil(try store.loadConnectionURL())
        try store.deleteConnectionURL()
    }

    /// Saving a different URL over a stored one must replace it. The update
    /// once matched on the new bytes and silently kept the old URL.
    func testKeychainOverwriteWithADifferentURL() throws {
        let store = KeychainCraftCredentialStore(
            service: "ccp.test.craft.\(UUID().uuidString)")
        try store.saveConnectionURL(URL(string: "https://connect.craft.do/links/aaa/api/v1")!)
        let replacement = URL(string: "https://connect.craft.do/links/bbb/api/v1")!
        try store.saveConnectionURL(replacement)
        XCTAssertEqual(try store.loadConnectionURL(), replacement)
        try store.deleteConnectionURL()
    }

    // MARK: - File store

    private func fileStore(keychain: KeychainCraftCredentialStore? = nil) -> (FileCraftCredentialStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccp.test.craft.\(UUID().uuidString)", isDirectory: true)
        let store = FileCraftCredentialStore(
            fileURL: dir.appendingPathComponent("craft-connection-url"),
            keychain: keychain)
        return (store, dir)
    }

    func testFileRoundTripsAndDeletes() throws {
        let (store, dir) = fileStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(try store.loadConnectionURL())
        let url = URL(string: "https://connect.craft.do/links/x/api/v1")!
        try store.saveConnectionURL(url)
        XCTAssertEqual(try store.loadConnectionURL(), url)
        try store.saveConnectionURL(url)
        XCTAssertEqual(try store.loadConnectionURL(), url)
        try store.deleteConnectionURL()
        XCTAssertNil(try store.loadConnectionURL())
        try store.deleteConnectionURL()
    }

    func testFileOverwriteWithADifferentURL() throws {
        let (store, dir) = fileStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.saveConnectionURL(URL(string: "https://connect.craft.do/links/aaa/api/v1")!)
        let replacement = URL(string: "https://connect.craft.do/links/bbb/api/v1")!
        try store.saveConnectionURL(replacement)
        XCTAssertEqual(try store.loadConnectionURL(), replacement)
    }

    func testFileIsOwnerOnly() throws {
        let (store, dir) = fileStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.saveConnectionURL(URL(string: "https://connect.craft.do/links/x/api/v1")!)
        let url = dir.appendingPathComponent("craft-connection-url")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testBlankFileReadsAsMissing() throws {
        let (store, dir) = fileStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("  \n".utf8).write(to: dir.appendingPathComponent("craft-connection-url"))
        XCTAssertNil(try store.loadConnectionURL())
    }

    /// The one-time move off the Keychain: a stored item is filed, removed,
    /// and served from the file from then on. The uniquely-named item keeps
    /// this off the real credential.
    func testMigratesAKeychainItemOnce() throws {
        let keychain = KeychainCraftCredentialStore(service: "ccp.test.craft.\(UUID().uuidString)")
        let url = URL(string: "https://connect.craft.do/links/x/api/v1")!
        try keychain.saveConnectionURL(url)
        let (store, dir) = fileStore(keychain: keychain)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? keychain.deleteConnectionURL()
        }
        XCTAssertEqual(try store.loadConnectionURL(), url)
        XCTAssertEqual(try store.loadConnectionURL(), url, "the second load serves the file")
        XCTAssertNil(try keychain.loadConnectionURL(), "migration removes the item it moved")
    }

    func testFileWinsOverKeychainAndLeavesItAlone() throws {
        let keychain = KeychainCraftCredentialStore(service: "ccp.test.craft.\(UUID().uuidString)")
        let filed = URL(string: "https://connect.craft.do/links/filed/api/v1")!
        let chained = URL(string: "https://connect.craft.do/links/chained/api/v1")!
        try keychain.saveConnectionURL(chained)
        let (store, dir) = fileStore(keychain: keychain)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? keychain.deleteConnectionURL()
        }
        try store.saveConnectionURL(filed)
        XCTAssertEqual(try store.loadConnectionURL(), filed)
        XCTAssertEqual(try keychain.loadConnectionURL(), chained)
    }

    /// Forgetting must reach the orphan too, or the next launch re-migrates
    /// a credential the user explicitly destroyed.
    func testForgetClearsTheFileAndAnyOrphanedKeychainItem() throws {
        let keychain = KeychainCraftCredentialStore(service: "ccp.test.craft.\(UUID().uuidString)")
        try keychain.saveConnectionURL(URL(string: "https://connect.craft.do/links/old/api/v1")!)
        let (store, dir) = fileStore(keychain: keychain)
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.saveConnectionURL(URL(string: "https://connect.craft.do/links/current/api/v1")!)
        try store.deleteConnectionURL()
        XCTAssertNil(try keychain.loadConnectionURL())
        let later = FileCraftCredentialStore(
            fileURL: dir.appendingPathComponent("craft-connection-url"),
            keychain: keychain)
        XCTAssertNil(try later.loadConnectionURL(), "nothing left to resurrect")
    }

    // MARK: - Store failures

    /// A store that fails every Keychain operation the way a locked Keychain
    /// does. The model must never present failure as success.
    private final class LockedStore: CraftCredentialStore, @unchecked Sendable {
        var url: URL?
        var failLoads = false
        private let status: OSStatus = errSecInteractionNotAllowed

        func loadConnectionURL() throws -> URL? {
            if failLoads { throw CraftKeychainError(status: status) }
            return url
        }

        func saveConnectionURL(_ url: URL) throws {
            throw CraftKeychainError(status: status)
        }

        func deleteConnectionURL() throws {
            throw CraftKeychainError(status: status)
        }
    }

    func testAFailedSaveKeepsTheEnteredTextAndStoresNothing() {
        let model = CraftConnectionModel(store: LockedStore(),
                                         transport: FakeTransport(statusCode: 200,
                                                                  json: Self.connectionJSON))
        model.urlText = "https://connect.craft.do/links/x/api/v1"
        model.save()
        XCTAssertEqual(model.status, .unreachable)
        XCTAssertFalse(model.isConfigured)
        XCTAssertNil(model.baseURL)
        XCTAssertEqual(model.urlText, "https://connect.craft.do/links/x/api/v1",
                       "a failed save must not eat the pasted URL")
    }

    func testAFailedForgetKeepsTheConfiguredState() {
        let store = LockedStore()
        store.url = URL(string: "https://connect.craft.do/links/x/api/v1")!
        let model = CraftConnectionModel(store: store,
                                         transport: FakeTransport(statusCode: 200,
                                                                  json: Self.connectionJSON))
        XCTAssertTrue(model.isConfigured)
        model.forget()
        XCTAssertTrue(model.isConfigured,
                      "Forget must not claim success while the item survives")
        XCTAssertNotNil(model.baseURL)
    }

    func testAReadFailureKeepsTheConfiguredState() async {
        let store = LockedStore()
        store.url = URL(string: "https://connect.craft.do/links/x/api/v1")!
        let model = CraftConnectionModel(store: store,
                                         transport: FakeTransport(statusCode: 200,
                                                                  json: Self.connectionJSON))
        store.failLoads = true
        model.verify()
        XCTAssertEqual(model.status, .unreachable)
        XCTAssertTrue(model.isConfigured,
                      "a transient read error is not a missing credential")
    }
}
