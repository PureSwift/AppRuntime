import Dispatch
import DynamicAuthentication
import DynamicRuntime
import RuntimeABI
import RuntimeCore
import RuntimeHost

/// The platform's sign-in page: `ASWebAuthenticationSession`, Custom Tabs,
/// the system's browser. Everything is called on the main thread.
///
/// The page is the system's browser, never a web view of the host's own.
/// `HostWebAuthentication` has checked the URL and the redirect before a
/// presenter sees them, and shows one page at a time.
public protocol WebAuthenticationPresenter: AnyObject {

    /// The redirect for a scheme and a path on this platform. The default
    /// is `scheme:/path`; a browser host gives an `https` address of the
    /// page's own. Whatever it gives for a path must begin with what it
    /// gives for no path.
    func redirectURL(scheme: String, path: String) -> String

    /// Shows `url`, and calls `completion` once, on the main thread: with
    /// the whole URL the provider redirected to, when it's one that begins
    /// with `redirect`, or with `canceledLogin` when the user closed the
    /// page. A redirect no page is waiting for is dropped.
    func present(_ url: String, redirect: String, ephemeral: Bool, completion: @escaping (Result<String, WebAuthenticationError>) -> Void)

    /// Closes the page. `HostWebAuthentication` has already answered the
    /// guest; a completion after this is ignored.
    func cancel()
}

public extension WebAuthenticationPresenter {

    func redirectURL(scheme: String, path: String) -> String {
        HostWebAuthentication.schemeRedirect(scheme: scheme, path: path)
    }
}

/// The `WebAuthentication` contract over a host's
/// `WebAuthenticationPresenter`: what every host written in Swift shares.
///
/// It refuses a URL that isn't `https` and a redirect whose scheme the
/// manifest doesn't declare, shows one page at a time, and answers each
/// sign-in once, on the main thread.
///
/// ```swift
/// HostWebAuthentication.presenter = MyBrowser()
/// HostWebAuthentication.declaredSchemes = Set(info.authenticationSchemes)
/// HostWebAuthenticationModule.register(in: runtime)
/// ```
///
/// Without a presenter a sign-in fails with `unsupported`. Main thread
/// only.
public final class HostWebAuthentication: WebAuthentication {

    // MARK: The host's settings

    /// The platform's sign-in page.
    nonisolated(unsafe) public static var presenter: (any WebAuthenticationPresenter)?

    /// The manifest's `authenticationSchemes`: `RTAuthenticationSchemes`
    /// in the bundle's `Info.plist`.
    nonisolated(unsafe) public static var declaredSchemes: Set<String> = []

    /// Runs an answer on the main thread. The default is the main dispatch
    /// queue; a host with a loop of its own posts to that.
    nonisolated(unsafe) public static var deliver: @Sendable (@escaping @Sendable () -> Void) -> Void = defaultDeliver

    private static let defaultDeliver: @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    /// The one object. Never replaced: a guest keeps the one it first
    /// asked for.
    nonisolated(unsafe) private static let instance = HostWebAuthentication()

    public static func shared() -> HostWebAuthentication {
        instance
    }

    /// Forgets the presenter, the schemes and a sign-in that's showing,
    /// for tests and for a host that starts the guest again.
    public static func reset() {
        presenter = nil
        declaredSchemes = []
        deliver = defaultDeliver
        instance.showing = nil
        instance.generation &+= 1
    }

    /// `scheme:/path`, the redirect of a platform with URL schemes.
    public static func schemeRedirect(scheme: String, path: String) -> String {
        var path = path[...]
        while path.first == "/" {
            path = path.dropFirst()
        }
        return scheme + ":/" + path
    }

    // MARK: A sign-in

    /// The callback of the page that's showing.
    private var showing: (any WebAuthenticationCallback)?

    /// Counts sign-ins, so a presenter's late completion is told from the
    /// current one's.
    private var generation = 0

    /// Whether a sign-in page is showing.
    public var isShowing: Bool {
        showing != nil
    }

    /// Calls `answer` with the callback, on the main thread and later.
    private static func later(_ callback: any WebAuthenticationCallback, _ answer: @escaping (any WebAuthenticationCallback) -> Void) {
        let held = MainThreadHeld((callback, answer))
        deliver {
            guard let (callback, answer) = held.take() else { return }
            answer(callback)
        }
    }

    private static func fail(_ callback: any WebAuthenticationCallback, _ error: WebAuthenticationError) {
        later(callback) { $0.didFail(error.rawValue) }
    }

    public func redirectURL(_ scheme: String, path: String) -> String {
        Self.presenter?.redirectURL(scheme: scheme, path: path) ?? Self.schemeRedirect(scheme: scheme, path: path)
    }

    /// Whether a redirect is one this host gives for a declared scheme.
    private func isDeclared(_ redirect: String) -> Bool {
        Self.declaredSchemes.contains { redirect.hasPrefix(redirectURL($0, path: "")) }
    }

    public func authenticate(_ url: String, redirect: String, ephemeral: Bool, callback: any WebAuthenticationCallback) {
        guard url.lowercased().hasPrefix("https://"), isDeclared(redirect) else {
            Self.fail(callback, .invalidURL)
            return
        }
        guard let presenter = Self.presenter else {
            Self.fail(callback, .unsupported)
            return
        }
        guard showing == nil else {
            Self.fail(callback, .busy)
            return
        }
        showing = callback
        generation &+= 1
        let current = generation
        presenter.present(url, redirect: redirect, ephemeral: ephemeral) { [self] result in
            // Heard once, and not after a cancel or another sign-in.
            guard generation == current, let callback = showing else { return }
            showing = nil
            switch result {
            case .success(let url) where url.hasPrefix(redirect):
                Self.later(callback) { $0.didAuthenticate(url) }
            case .success:
                // Not the redirect that was waited for.
                Self.fail(callback, .unknown)
            case .failure(let error):
                Self.fail(callback, error)
            }
        }
    }

    public func cancel() {
        guard let callback = showing else { return }
        showing = nil
        generation &+= 1
        Self.fail(callback, .canceledLogin)
        Self.presenter?.cancel()
    }
}

/// The sign-in module: the contract and its callback.
public enum HostWebAuthenticationModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [WebAuthenticationProxy.descriptor, WebAuthenticationCallbackProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        WebAuthenticationProxy.register(HostWebAuthentication.self, in: registrar)
        WebAuthenticationCallbackProxy.registerInterface(in: registrar)
    }
}
