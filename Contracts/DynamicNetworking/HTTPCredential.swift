import DynamicRuntime

/// A user name and password answering an authentication challenge
/// (`URLCredential`, OkHttp `Credentials`).
@DynamicRuntime("org.pureswift.network.HTTPCredential")
public protocol HTTPCredential: AnyObject {

    /// `persistence` is an `HTTPCredentialPersistence` raw value. The
    /// password is write-only.
    static func make(user: String, password: String, persistence: Int32) -> Self

    func user() -> String

    func persistence() -> Int32
}
