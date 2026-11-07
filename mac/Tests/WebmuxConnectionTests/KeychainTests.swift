import XCTest
@testable import WebmuxConnection

final class KeychainTests: XCTestCase {
    func testInMemoryStore() throws {
        let s = InMemoryPasswordStore()
        XCTAssertEqual(s.lookup(profileID: "a"), .none)
        XCTAssertFalse(s.has(profileID: "a"))
        try s.set(profileID: "a", label: "webmux: a", password: "pw")
        XCTAssertTrue(s.has(profileID: "a"))
        XCTAssertEqual(s.lookup(profileID: "a"), .found("pw"))
        s.unavailable = "locked"
        XCTAssertEqual(s.lookup(profileID: "a"), .unavailable("locked"))
        XCTAssertTrue(s.has(profileID: "a")) // stored, even when unreadable
        s.unavailable = nil
        try s.delete(profileID: "a")
        try s.delete(profileID: "a")
        XCTAssertEqual(s.lookup(profileID: "a"), .none)
    }

    /// Against the real login keychain, under a test-only service name.
    /// Skipped where the keychain refuses non-interactive access.
    func testKeychainSetGetDelete() throws {
        let kc = Keychain(service: "me.puntium.webmux.mac.tests")
        let id = Util.randomHex(bytes: 8)
        defer { try? kc.delete(profileID: id) }
        do {
            try kc.set(profileID: id, label: "webmux test: \(id)", password: "s3cr3t-pw ü")
        } catch let e as KeychainError {
            throw XCTSkip("no usable keychain in this test host: \(e)")
        }
        XCTAssertTrue(kc.has(profileID: id))
        XCTAssertFalse(kc.has(profileID: "0000000000000000"))
        XCTAssertEqual(kc.lookup(profileID: id), .found("s3cr3t-pw ü"))
        XCTAssertEqual(kc.lookup(profileID: "0000000000000000"), .none)
        // replace
        try kc.set(profileID: id, label: "webmux test: \(id)", password: "second")
        XCTAssertEqual(kc.lookup(profileID: id), .found("second"))
        XCTAssertTrue(kc.allProfileIDs().contains(id))
        try kc.delete(profileID: id)
        XCTAssertFalse(kc.has(profileID: id))
        XCTAssertEqual(kc.lookup(profileID: id), .none)
        try kc.delete(profileID: id) // not an error
        XCTAssertEqual(KeychainError(status: errSecNotAvailable, operation: "set").userMessage, "OS keychain encryption is unavailable — cannot store a password")
    }
}
