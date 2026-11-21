import DynamicRuntime

/// Signing in on a web page the system's browser shows
/// (`Documentation/Contracts/Secrets.md`). App code uses
/// `WebAuthenticationSession`, which wraps this contract.
///
/// The host opens a URL and gives back the URL the account's provider
/// redirected to. The page is the system's browser, never a web view of
/// the host's own: the guest can't see it, script it or read its cookies.
/// The host knows nothing of OAuth and checks nothing in the redirect.
///
/// It needs no capability. The redirect's scheme is declared in the
/// manifest's `authenticationSchemes`.
///
/// | Host | Implementation |
/// |---|---|
/// | iOS / macOS | `ASWebAuthenticationSession` |
/// | Android | Custom Tabs, and an intent for the redirect |
/// | Linux | the system's browser, and a handler for the redirect |
/// | Browser | a pop-up window |
@DynamicRuntime("org.pureswift.authentication.WebAuthentication")
public protocol WebAuthentication: AnyObject {

    static func shared() -> Self

    /// The redirect for a scheme and a path, on this host: `scheme:/path`
    /// on a native one, an `https` address of the page's own in a browser.
    func redirectURL(_ scheme: String, path: String) -> String

    /// Shows `url`, which is `https`, and waits for a redirect that begins
    /// with `redirect`, which `redirectURL` gave for a declared scheme.
    /// One at a time. Answered by `didAuthenticate` or `didFail`.
    func authenticate(_ url: String, redirect: String, ephemeral: Bool, callback: WebAuthenticationCallback)

    /// Closes the page that's showing: its callback gets `canceledLogin`.
    func cancel()
}

/// A sign-in's answer, from the host. Called once, on the main thread.
@DynamicCallback("org.pureswift.authentication.Callback")
public protocol WebAuthenticationCallback: AnyObject {

    /// The whole URL the provider redirected to.
    func didAuthenticate(_ url: String)

    /// A `WebAuthenticationError` raw value.
    func didFail(_ error: Int32)
}
