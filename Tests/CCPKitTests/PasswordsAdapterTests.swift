// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

@testable import CCPKit
import Security
import XCTest

@MainActor
final class PasswordsAdapterTests: XCTestCase {
    // MARK: - Site parsing

    func testNormalizedServerShedsSchemePathAndCase() {
        XCTAssertEqual(PasswordsAdapter.normalizedServer("https://Example.com/login"), "example.com")
        XCTAssertEqual(PasswordsAdapter.normalizedServer("example.com"), "example.com")
        XCTAssertEqual(PasswordsAdapter.normalizedServer("  EXAMPLE.com. "), "example.com")
    }

    func testSchemeWithoutHostParsesToNothing() {
        XCTAssertEqual(PasswordsAdapter.normalizedServer("https://"), "")
        XCTAssertEqual(PasswordsAdapter.normalizedServer("http://"), "")
        XCTAssertEqual(PasswordsAdapter.normalizedServer("https://?x"), "")
    }

    func testParseKeepsExplicitSchemeAndPort() {
        let site = PasswordSite.parse("http://192.168.1.1:8080/login")
        XCTAssertEqual(site?.server, "192.168.1.1")
        XCTAssertEqual(site?.port, 8080)
        XCTAssertEqual(
            PasswordsAdapter.addQuery(site: site!, account: "u", password: "p")[kSecAttrProtocol as String] as? String,
            kSecAttrProtocolHTTP as String)
    }

    func testParseDropsDefaultPorts() {
        XCTAssertNil(PasswordSite.parse("https://example.com:443")?.port)
        XCTAssertNil(PasswordSite.parse("http://example.com:80")?.port)
        XCTAssertEqual(PasswordSite.parse("example.com:8080")?.port, 8080)
    }

    // MARK: - Validation

    func testValidateRejectsBlankFields() {
        XCTAssertEqual(
            PasswordsAdapter.validate(site: "  ", username: "u", password: "p"), .emptySite)
        XCTAssertEqual(
            PasswordsAdapter.validate(site: "https://", username: "u", password: "p"), .emptySite)
        XCTAssertEqual(
            PasswordsAdapter.validate(site: "example.com", username: "  ", password: "p"), .emptyUsername)
        XCTAssertEqual(
            PasswordsAdapter.validate(site: "example.com", username: "u", password: ""), .emptyPassword)
        XCTAssertNil(
            PasswordsAdapter.validate(site: "https://example.com/a", username: "u", password: "p"))
    }

    // MARK: - Save

    func testSaveWritesNormalizedServerAndReportsIt() async {
        let store = FakePasswordsStore()
        let adapter = PasswordsAdapter(store: store, launcher: FakePasswordsLauncher())
        let saved = await adapter.save(site: "https://Example.com/login", username: " u ", password: "s3cret")
        XCTAssertTrue(saved)
        XCTAssertEqual(store.saved?.site.server, "example.com")
        XCTAssertEqual(store.saved?.account, "u")
        XCTAssertEqual(store.saved?.password, "s3cret")
        XCTAssertTrue(adapter.notice?.contains("example.com") == true)
    }

    func testSaveValidationFailureTouchesNothing() async {
        let store = FakePasswordsStore()
        let adapter = PasswordsAdapter(store: store, launcher: FakePasswordsLauncher())
        let saved = await adapter.save(site: "", username: "u", password: "p")
        XCTAssertFalse(saved)
        XCTAssertNil(store.saved)
        XCTAssertEqual(adapter.notice, "Enter a site first.")
    }

    func testSaveKeychainFailureReadsGeneric() async {
        let store = FakePasswordsStore(error: .keychain(errSecIO))
        let adapter = PasswordsAdapter(store: store, launcher: FakePasswordsLauncher())
        let saved = await adapter.save(site: "example.com", username: "u", password: "p")
        XCTAssertFalse(saved)
        XCTAssertEqual(adapter.notice, "Couldn't save that login.")
    }

    // MARK: - Generator

    func testGeneratePasswordUsesFullLengthAndAlphabet() {
        let alphabet = Set("abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789!@#$%^&*-_?")
        let password = PasswordsAdapter.generatePassword(length: 32)
        XCTAssertEqual(password.count, 32)
        XCTAssertTrue(password.allSatisfy(alphabet.contains), "generator left the unambiguous alphabet")
    }

    // MARK: - Launcher

    func testOpenPasswordsReachesLauncher() {
        let launcher = FakePasswordsLauncher()
        let adapter = PasswordsAdapter(store: FakePasswordsStore(), launcher: launcher)
        adapter.openPasswords()
        XCTAssertEqual(launcher.openCount, 1)
        XCTAssertNil(adapter.notice)
    }

    func testOpenPasswordsFailureReadsInline() {
        let launcher = FakePasswordsLauncher(opens: false)
        let adapter = PasswordsAdapter(store: FakePasswordsStore(), launcher: launcher)
        adapter.openPasswords()
        XCTAssertEqual(adapter.notice, "Couldn't open Passwords on this Mac.")
    }

    // MARK: - Keychain query shape

    func testAddQueryIsASyncableInternetPassword() {
        let site = PasswordSite.parse("example.com")!
        let query = PasswordsAdapter.addQuery(site: site, account: "u", password: "p")
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassInternetPassword as String)
        XCTAssertEqual(query[kSecAttrServer as String] as? String, "example.com")
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, true)
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertNil(query[kSecAttrAccessible as String], "ThisDeviceOnly accessibles cannot sync")
    }

    func testMatchQuerySeesSyncableAndLocalTwinsCarriesNoSecret() {
        let site = PasswordSite.parse("example.com")!
        let query = PasswordsAdapter.matchQuery(site: site, account: "u")
        XCTAssertNil(query[kSecValueData as String])
        XCTAssertEqual(
            query[kSecAttrSynchronizable as String] as? String,
            kSecAttrSynchronizableAny as String)
    }
}

// MARK: - Fakes

private final class FakePasswordsStore: PasswordsStore, @unchecked Sendable {
    struct Saved: Equatable {
        let site: PasswordSite
        let account: String
        let password: String
    }

    var saved: Saved?
    let error: PasswordsSaveError?

    init(error: PasswordsSaveError? = nil) {
        self.error = error
    }

    func save(site: PasswordSite, account: String, password: String) throws {
        if let error { throw error }
        saved = Saved(site: site, account: account, password: password)
    }
}

private final class FakePasswordsLauncher: PasswordsLauncher, @unchecked Sendable {
    var openCount = 0
    let opens: Bool

    init(opens: Bool = true) {
        self.opens = opens
    }

    func openPasswords() -> Bool {
        openCount += 1
        return opens
    }
}
