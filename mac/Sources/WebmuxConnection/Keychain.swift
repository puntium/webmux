// Saved ssh passwords in the login Keychain (deviation 3): one generic
// password item per profile, service = bundle id, account = profile id,
// label "webmux: <profile name>". The plaintext is read only on an engine
// thread right before an ssh spawn, goes into the child's environment for
// the askpass helper, and is never logged.
//
// The engine sees the store through `PasswordStore`, so tests run against
// `InMemoryPasswordStore` and the Keychain itself is exercised only where
// an interactive keychain exists.
import Foundation
import Security

public enum PasswordLookup: Sendable, Equatable {
    /// No saved password: key-only auth (BatchMode=yes).
    case none
    /// The saved password.
    case found(String)
    /// The store refused (locked, unavailable). The connection parks as
    /// failed with main.js's "could not be decrypted" message; the text here
    /// is logged.
    case unavailable(String)
}

public protocol PasswordStore: Sendable {
    /// Called on engine threads before every ssh spawn for a profile (each
    /// connect attempt, each Restart Sessions); may block.
    func lookup(profileID: String) -> PasswordLookup
    /// Whether a password is saved for the profile (for the `connect
    /// requested` line's `auth` field: main.js logs whether one is stored,
    /// not whether it could be read). Main or engine thread; must not prompt.
    func has(profileID: String) -> Bool
    /// Save or replace. `label` is shown in Keychain Access.
    func set(profileID: String, label: String, password: String) throws
    /// Forget. Not an error when there is nothing to forget.
    func delete(profileID: String) throws
}

public struct KeychainError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public let operation: String
    public var description: String {
        let msg = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
        return "\(operation): \(msg) (\(status))"
    }
    /// main.js X-10: "OS keychain encryption is unavailable — cannot store a password".
    public var userMessage: String {
        operation == "set" ? "OS keychain encryption is unavailable — cannot store a password" : description
    }
}

/// The real thing. `service` is the bundle id; tests pass their own.
public final class Keychain: PasswordStore, @unchecked Sendable {
    public let service: String

    public init(service: String = webmuxBundleID) {
        self.service = service
    }

    private func baseQuery(_ profileID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: profileID]
    }

    public func lookup(profileID: String) -> PasswordLookup {
        var q = baseQuery(profileID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data, let s = String(data: data, encoding: .utf8) else {
                return .unavailable("keychain item is not text")
            }
            return .found(s)
        case errSecItemNotFound:
            return .none
        default:
            return .unavailable(KeychainError(status: status, operation: "lookup").description)
        }
    }

    public func has(profileID: String) -> Bool {
        var q = baseQuery(profileID)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    public func set(profileID: String, label: String, password: String) throws {
        let data = Data(password.utf8)
        let q = baseQuery(profileID)
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
        var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = label
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { throw KeychainError(status: status, operation: "set") }
    }

    public func delete(profileID: String) throws {
        let status = SecItemDelete(baseQuery(profileID) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { throw KeychainError(status: status, operation: "delete") }
    }

    /// A list of the profile ids with an item, for forgetting orphans.
    public func allProfileIDs() -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// A fake for tests and for running without a keychain.
public final class InMemoryPasswordStore: PasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    /// When set, every lookup answers `.unavailable(reason)`.
    public var unavailable: String? {
        get { lock.withLock { _unavailable } }
        set { lock.withLock { _unavailable = newValue } }
    }
    private var _unavailable: String?

    public init() {}

    public func lookup(profileID: String) -> PasswordLookup {
        lock.withLock {
            if let u = _unavailable { return .unavailable(u) }
            if let p = items[profileID] { return .found(p) }
            return .none
        }
    }

    public func has(profileID: String) -> Bool {
        lock.withLock { items[profileID] != nil }
    }

    public func set(profileID: String, label: String, password: String) throws {
        lock.withLock { items[profileID] = password }
    }

    public func delete(profileID: String) throws {
        lock.withLock { _ = items.removeValue(forKey: profileID) }
    }
}
