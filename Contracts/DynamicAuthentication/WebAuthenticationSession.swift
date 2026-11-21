import DynamicRuntime
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// Why a sign-in gave no redirect.
public enum WebAuthenticationError: Int32, Error, Sendable {

    case unknown = 0

    /// The user closed the page, the app cancelled, or the task waiting
    /// was cancelled.
    case canceledLogin = 1

    /// A URL that isn't `https`, or a redirect whose scheme the manifest
    /// doesn't declare.
    case invalidURL = 2

    /// A sign-in is already showing.
    case busy = 3

    /// The platform refused: the call didn't come from a user action, or
    /// the app isn't in front.
    case notAllowed = 4

    /// This host has no browser to show.
    case unsupported = 5
}

/// One sign-in with an account's provider, on a page the system's browser
/// shows: SwiftUI's `WebAuthenticationSession`.
///
/// ```swift
/// let session = WebAuthenticationSession()
/// let redirect = session.redirectURL(scheme: "com.example.mail", path: "oauth")
/// let callback = try await session.authenticate(
///     using: "https://accounts.example.com/authorize?…&redirect_uri=" + encoded(redirect),
///     redirect: redirect)
/// // "com.example.mail:/oauth?code=…&state=…"
/// ```
///
/// The app builds the URL and checks what comes back: its `state`, and the
/// code. The host only shows the one and returns the other. The app can't
/// see the page, or what's typed into it.
///
/// Ask the host for the redirect: a native host calls the app back through
/// a URL scheme of its own, which the manifest's `authenticationSchemes`
/// declares, and a browser host through an `https` page. A provider wants
/// each registered.
///
/// It's guest-side only, over the `WebAuthentication` contract. The guest
/// is single-threaded (§6.4).
public struct WebAuthenticationSession: Sendable {

    /// Which of the browser's sessions the page uses.
    public enum BrowserSession: Sendable {

        /// The user's own, with the accounts they're signed in to.
        case shared

        /// One with no cookies from before, and none kept after: for
        /// signing in to a second account. A host that can't shows the
        /// ordinary page.
        case ephemeral
    }

    public init() { }

    private var authentication: any WebAuthentication {
        WebAuthenticationProxy.shared()
    }

    /// The redirect to register with the provider and put in the URL:
    /// `scheme:/path` on a native host, and an `https` address of the
    /// page's own in a browser.
    public func redirectURL(scheme: String, path: String = "") -> String {
        authentication.redirectURL(scheme, path: path)
    }

    /// Shows `url`, and gives the whole URL the provider redirected to,
    /// once it's one that begins with `redirect`. Call it from a user
    /// action; one at a time.
    public func authenticate(using url: String, redirect: String, preferredBrowserSession: BrowserSession = .shared, completion: @escaping (Result<String, WebAuthenticationError>) -> Void) {
        authentication.authenticate(url, redirect: redirect, ephemeral: preferredBrowserSession == .ephemeral, callback: Receiver(completion))
    }

    /// Closes the page that's showing; its call fails with
    /// `canceledLogin`.
    public func cancel() {
        authentication.cancel()
    }

    #if !EMBEDDED_NO_CONCURRENCY
    /// - Throws: `WebAuthenticationError`. Cancelling the task closes the
    ///   page.
    public nonisolated(nonsending) func authenticate(using url: String, redirect: String, preferredBrowserSession: BrowserSession = .shared) async throws(WebAuthenticationError) -> String {
        try await withCallback { (callback: Callback<String, WebAuthenticationError>) in
            self.authenticate(using: url, redirect: redirect, preferredBrowserSession: preferredBrowserSession) {
                callback.resume(with: $0)
            }
        } onCancel: { callback in
            WebAuthenticationProxy.shared().cancel()
            callback.resume(throwing: .canceledLogin)
        }
    }

    /// SwiftUI's form: any redirect to `callbackURLScheme`.
    public nonisolated(nonsending) func authenticate(using url: String, callbackURLScheme: String, preferredBrowserSession: BrowserSession = .shared) async throws(WebAuthenticationError) -> String {
        try await authenticate(using: url, redirect: redirectURL(scheme: callbackURLScheme), preferredBrowserSession: preferredBrowserSession)
    }
    #endif
}

/// A sign-in's callback. The host holds it until it answers.
private final class Receiver: WebAuthenticationCallback {

    private var finish: ((Result<String, WebAuthenticationError>) -> Void)?

    init(_ finish: @escaping (Result<String, WebAuthenticationError>) -> Void) {
        self.finish = finish
    }

    /// Only a host's first answer counts.
    private func answer(_ result: Result<String, WebAuthenticationError>) {
        guard let finish else { return }
        self.finish = nil
        finish(result)
    }

    func didAuthenticate(_ url: String) {
        answer(.success(url))
    }

    func didFail(_ error: Int32) {
        answer(.failure(WebAuthenticationError(rawValue: error) ?? .unknown))
    }
}
