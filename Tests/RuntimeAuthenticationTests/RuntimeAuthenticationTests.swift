import Foundation
import Testing
import DynamicAuthentication
import DynamicRuntime
import RuntimeCore
import RuntimeHost
import RuntimeNative
@testable import RuntimeAuthentication

/// The system's browser, played by the test: it keeps each page's
/// completion and answers as a provider or a user would.
final class TestBrowser: WebAuthenticationPresenter {

    struct Page {
        var url: String
        var redirect: String
        var ephemeral: Bool
        var completion: (Result<String, WebAuthenticationError>) -> Void
    }

    var pages: [Page] = []

    var cancels = 0

    func present(_ url: String, redirect: String, ephemeral: Bool, completion: @escaping (Result<String, WebAuthenticationError>) -> Void) {
        pages.append(Page(url: url, redirect: redirect, ephemeral: ephemeral, completion: completion))
    }

    func cancel() {
        cancels += 1
    }

    /// The provider sends the user back.
    func redirect(_ url: String) {
        pages.last?.completion(.success(url))
    }

    /// The user closes the page.
    func close() {
        pages.last?.completion(.failure(.canceledLogin))
    }
}

/// A browser host's presenter: the redirect is a page of the app's own.
final class WebPageBrowser: WebAuthenticationPresenter {

    var presented: [String] = []

    func redirectURL(scheme: String, path: String) -> String {
        "https://app.example/rt-auth/\(scheme)/\(path)"
    }

    func present(_ url: String, redirect: String, ephemeral: Bool, completion: @escaping (Result<String, WebAuthenticationError>) -> Void) {
        presented.append(redirect)
        completion(.success(redirect + "?code=web"))
    }

    func cancel() { }
}

/// `HostWebAuthentication` over a browser the test plays, driven from the
/// guest's `WebAuthenticationSession` through the runtime.
///
/// Serialized: `HostWebAuthentication` and the native runtime are shared.
@Suite(.serialized) final class RuntimeAuthenticationTests {

    static let authorize = "https://id.example/authorize?client_id=abc"

    let browser = TestBrowser()

    let session = WebAuthenticationSession()

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        HostWebAuthentication.reset()
        HostWebAuthentication.presenter = browser
        HostWebAuthentication.declaredSchemes = ["org.example.app"]
        HostWebAuthentication.deliver = { $0() }
        HostWebAuthenticationModule.register(in: native)
    }

    deinit {
        HostWebAuthentication.reset()
    }

    /// Starts a sign-in, and says what it has answered so far.
    func signIn(_ url: String = RuntimeAuthenticationTests.authorize, redirect: String = "org.example.app:/oauth",
                _ browserSession: WebAuthenticationSession.BrowserSession = .shared) -> () -> Result<String, WebAuthenticationError>? {
        var result: Result<String, WebAuthenticationError>?
        session.authenticate(using: url, redirect: redirect, preferredBrowserSession: browserSession) { result = $0 }
        return { result }
    }

    func failure(_ result: Result<String, WebAuthenticationError>?) -> WebAuthenticationError? {
        if case .failure(let error)? = result { return error }
        return nil
    }

    @Test func moduleListsItsContracts() {
        #expect(HostWebAuthenticationModule.contracts.map(\.name) == [
            "org.pureswift.authentication.WebAuthentication", "org.pureswift.authentication.Callback",
        ])
        #expect(HostWebAuthenticationModule.permissionProviders().isEmpty)
        #expect(HostWebAuthentication.shared() === HostWebAuthentication.shared())
    }

    @Test func aNativeHostsRedirectIsTheAppsScheme() {
        #expect(session.redirectURL(scheme: "org.example.app", path: "oauth") == "org.example.app:/oauth")
        #expect(session.redirectURL(scheme: "org.example.app") == "org.example.app:/")
        #expect(session.redirectURL(scheme: "org.example.app", path: "//a/b") == "org.example.app:/a/b", "one slash, whatever the path began with")
        HostWebAuthentication.presenter = nil
        #expect(session.redirectURL(scheme: "org.example.app", path: "oauth") == "org.example.app:/oauth", "with no browser, too")
    }

    @Test func theProvidersRedirectComesBackWhole() throws {
        let answer = signIn()
        #expect(answer() == nil && HostWebAuthentication.shared().isShowing)
        let page = try #require(browser.pages.last)
        #expect(page.url == Self.authorize && page.redirect == "org.example.app:/oauth" && !page.ephemeral)

        browser.redirect("org.example.app:/oauth?code=4%2F0A&state=xyz#frag")
        #expect(try answer()?.get() == "org.example.app:/oauth?code=4%2F0A&state=xyz#frag", "nothing in it is read or changed")
        #expect(!HostWebAuthentication.shared().isShowing)

        let private_ = signIn(redirect: "org.example.app:/", .ephemeral)
        #expect(browser.pages.last?.ephemeral == true)
        browser.redirect("org.example.app:/anything?code=1")
        #expect(try private_()?.get() == "org.example.app:/anything?code=1", "any redirect that begins with it")
    }

    @Test func onlyHTTPSAndDeclaredSchemesAreShown() {
        #expect(failure(signIn("http://id.example/authorize")()) == .invalidURL)
        #expect(failure(signIn("org.example.app:/oauth")()) == .invalidURL)
        #expect(failure(signIn("javascript:alert(1)")()) == .invalidURL)
        #expect(failure(signIn(redirect: "com.other.app:/oauth")()) == .invalidURL, "a scheme the manifest doesn't declare")
        #expect(failure(signIn(redirect: "https://evil.example/")()) == .invalidURL)
        #expect(failure(signIn(redirect: "org.example.app")()) == .invalidURL, "not a redirect the host gave")
        #expect(failure(signIn(redirect: "")()) == .invalidURL)
        #expect(browser.pages.isEmpty, "none of those opened a page")

        let upper = signIn("HTTPS://id.example/authorize")
        #expect(browser.pages.count == 1 && upper() == nil, "a scheme's case doesn't matter")
        browser.close()

        HostWebAuthentication.declaredSchemes = []
        #expect(failure(signIn()()) == .invalidURL, "nothing declared, nothing shown")
        HostWebAuthentication.declaredSchemes = ["org.example.app"]
        HostWebAuthentication.presenter = nil
        #expect(failure(signIn()()) == .unsupported, "no browser to show")
    }

    @Test func aRedirectThatWasNotWaitedForIsNotASignIn() {
        let answer = signIn()
        browser.redirect("org.example.app:/other?code=1")
        #expect(failure(answer()) == .unknown)
        #expect(!HostWebAuthentication.shared().isShowing)
    }

    @Test func oneSignInAtATime() throws {
        let first = signIn()
        let second = signIn()
        #expect(failure(second()) == .busy && first() == nil && browser.pages.count == 1)
        browser.close()
        #expect(failure(first()) == .canceledLogin, "the user closed the page")

        let third = signIn()
        #expect(browser.pages.count == 2)
        browser.redirect("org.example.app:/oauth?code=3")
        browser.redirect("org.example.app:/oauth?code=again")
        browser.close()
        #expect(try third()?.get() == "org.example.app:/oauth?code=3", "a browser that answers twice is heard once")
    }

    @Test func theAppCanCloseThePage() throws {
        session.cancel()
        #expect(browser.cancels == 0, "nothing was showing")

        let answer = signIn()
        session.cancel()
        #expect(failure(answer()) == .canceledLogin && browser.cancels == 1)
        #expect(!HostWebAuthentication.shared().isShowing)
        browser.redirect("org.example.app:/oauth?code=late")
        #expect(failure(answer()) == .canceledLogin, "what the browser says afterwards is ignored")

        // A late answer from the page before doesn't reach the next one.
        let next = signIn()
        browser.pages[0].completion(.success("org.example.app:/oauth?code=stale"))
        #expect(next() == nil)
        browser.redirect("org.example.app:/oauth?code=fresh")
        #expect(try next()?.get() == "org.example.app:/oauth?code=fresh")
    }

    @Test func aBrowserHostsRedirectIsItsOwnPage() throws {
        let web = WebPageBrowser()
        HostWebAuthentication.presenter = web
        let redirect = session.redirectURL(scheme: "org.example.app", path: "oauth")
        #expect(redirect == "https://app.example/rt-auth/org.example.app/oauth")
        let answer = signIn(redirect: redirect)
        #expect(try answer()?.get() == redirect + "?code=web", "a presenter may answer at once")
        #expect(failure(signIn(redirect: "org.example.app:/oauth")()) == .invalidURL, "a scheme isn't this host's redirect")
        #expect(failure(signIn(redirect: "https://app.example/rt-auth/com.other.app/oauth")()) == .invalidURL)
    }

    // The async tests run on the main actor, with their child tasks: the
    // guest is single-threaded.

    @MainActor @Test func aSignInCanBeAwaited() async throws {
        HostWebAuthentication.deliver = { DispatchQueue.main.async(execute: $0) }
        let browser = self.browser
        let session = self.session
        let waiting = Task { @MainActor in
            try await session.authenticate(using: Self.authorize, callbackURLScheme: "org.example.app")
        }
        while browser.pages.isEmpty { await Task.yield() }
        #expect(browser.pages[0].redirect == "org.example.app:/", "SwiftUI's form: any redirect to the scheme")
        browser.redirect("org.example.app:/done?code=7")
        #expect(try await waiting.value == "org.example.app:/done?code=7")

        // Cancelling the task closes the page.
        let abandoned = Task { @MainActor in
            try await session.authenticate(using: Self.authorize, redirect: "org.example.app:/oauth")
        }
        while browser.pages.count < 2 { await Task.yield() }
        abandoned.cancel()
        let result = await abandoned.result
        if case .failure(let error) = result {
            #expect(error as? WebAuthenticationError == .canceledLogin)
        } else {
            Issue.record("a cancelled sign-in gave a redirect")
        }
        #expect(browser.cancels == 1 && !HostWebAuthentication.shared().isShowing)
    }
}
