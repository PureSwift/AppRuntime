import DynamicRuntime

/// The system's store for an app's secrets: a token, a password
/// (`Documentation/Contracts/Secrets.md`). App code uses `Keychain`, which
/// wraps this contract.
///
/// A secret is the app's own, on this device: the host scopes every key to
/// the app, keeps secrets out of backups and off the user's other
/// devices, and removes them with the app. Every operation completes
/// through its `callback`, which the host holds until it has called
/// exactly one of its methods, on the main thread: a keyring may need the
/// user to unlock it, and a browser's storage can't be used synchronously.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS | Keychain Services |
/// | Android | a key in the Android Keystore, and the values it encrypts |
/// | Linux | the Secret Service |
/// | Browser | a key that can't be exported, and the values it encrypts |
@DynamicRuntime("org.pureswift.secrets.Secrets", requires: .secrets)
public protocol Secrets: AnyObject {

    static func shared() -> Self

    /// Stores `value` under `key`, replacing what was there.
    /// `accessibility` is a `KeychainAccessibility` raw value. Answered by
    /// `didComplete`.
    func set(_ key: String, value: [UInt8], accessibility: Int32, callback: SecretCallback)

    /// Answered by `didGet`.
    func get(_ key: String, callback: SecretCallback)

    /// No secret under `key` is no error. Answered by `didComplete`.
    func remove(_ key: String, callback: SecretCallback)

    /// Every secret of the app's. Answered by `didComplete`.
    func removeAll(_ callback: SecretCallback)

    /// Answered by `didList`.
    func keys(_ callback: SecretCallback)
}

/// One operation's answer, from the host. Called once, on the main thread.
@DynamicCallback("org.pureswift.secrets.Callback")
public protocol SecretCallback: AnyObject {

    func didComplete()

    /// `found` false: there's no such secret, and `value` is empty.
    func didGet(_ value: [UInt8], found: Bool)

    func didList(_ keys: [String])

    /// A `KeychainError` raw value.
    func didFail(_ error: Int32)
}
