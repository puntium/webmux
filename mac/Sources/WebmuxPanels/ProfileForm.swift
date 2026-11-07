// The profile form's model (W-27, W-28, X-03, X-04, X-10): the text of each
// field → a `ProfileInput` plus what to do with the password, or the first
// validation error. Pure; the window binds its fields to it.
import Foundation
import WebmuxConnection

/// What a save does with the saved password (X-10): a blank field keeps the
/// stored one, a non-blank one replaces it, the "clear saved" box removes it.
public enum PasswordAction: Equatable, Sendable {
    case keep
    case set(String)
    case clear
}

public struct ProfileFormValues: Equatable, Sendable {
    public var name = ""
    public var host = ""
    /// As typed; blank = ssh's default.
    public var sshPort = ""
    public var identityFile = ""
    public var instance = ""
    public var extraOptions = ""
    /// As typed; never stored here beyond the save.
    public var password = ""
    public var clearPassword = false

    public init() {}

    /// The stored profile's fields (the password is never shown: X-09).
    public init(profile: Profile) {
        name = profile.name
        host = profile.host
        sshPort = profile.sshPort == 0 ? "" : String(profile.sshPort)
        identityFile = profile.identityFile
        instance = profile.instance
        extraOptions = profile.extraOptions
    }

    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The input for `ConnectionEngine.saveProfile`, trimmed like the Electron
    /// form (X-03, X-04), or the error the form shows. The engine's own
    /// validation (unique name, instance rule) runs after this; `portError`
    /// is the one check that is the form's (deviation 39).
    public func input() -> Result<ProfileInput, FormError> {
        let name = Self.trim(self.name)
        let host = Self.trim(self.host)
        if name.isEmpty || host.isEmpty { return .failure(FormError("name and host are required")) }
        guard let port = Profile.parsePort(sshPort) else { return .failure(FormError(Profile.portError)) }
        let instance = Self.trim(self.instance)
        if !instance.isEmpty && !Profile.validInstance(instance) { return .failure(FormError(Profile.instanceError)) }
        return .success(ProfileInput(
            name: name, host: host, sshPort: port,
            identityFile: Self.trim(identityFile), instance: instance, extraOptions: Self.trim(extraOptions)))
    }

    /// X-10's rule.
    public var passwordAction: PasswordAction {
        if clearPassword { return .clear }
        if password.isEmpty { return .keep }
        return .set(password)
    }

    /// The password field's placeholder (W-27).
    public static func passwordPlaceholder(hasStored: Bool) -> String {
        hasStored ? "saved — leave blank to keep" : "blank = key auth (recommended)"
    }

    /// The row's title: where the password lives (deviation 3).
    public static let passwordLabel = "Password"
}

public struct FormError: Error, Equatable, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

/// The monospace detail line of a profile row (W-21): `<host>[ -p <port>][ → <instance>]`.
public func profileDetailLine(_ p: Profile) -> String {
    var s = p.host
    if p.sshPort != 0 { s += " -p \(p.sshPort)" }
    if !p.instance.isEmpty { s += " → \(p.instance)" }
    return s
}
