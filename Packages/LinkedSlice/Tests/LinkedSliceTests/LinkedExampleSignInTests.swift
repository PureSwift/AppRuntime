import Foundation
import Testing
import CRuntime
import DynamicAuthentication
import DynamicRuntime
import DynamicSecrets
import DynamicUI
import RuntimeABI
import RuntimeAuthentication
import RuntimeHost
import RuntimeNative
import RuntimeSecrets

/// The system's browser, played by the test: it keeps the page it was
/// asked to show, and answers as a provider or a user would.
final class LinkedSignInBrowser: WebAuthenticationPresenter {

    var url = ""

    var redirect = ""

    var ephemeral = false

    var pages = 0

    var cancels = 0

    private var completion: ((Result<String, WebAuthenticationError>) -> Void)?

    func present(_ url: String, redirect: String, ephemeral: Bool, completion: @escaping (Result<String, WebAuthenticationError>) -> Void) {
        self.url = url
        self.redirect = redirect
        self.ephemeral = ephemeral
        self.completion = completion
        pages += 1
    }

    func cancel() {
        cancels += 1
    }

    /// A parameter of the page's URL, as the app wrote it.
    func parameter(_ name: String) -> String? {
        URLComponents(string: url)?.percentEncodedQueryItems?.first { $0.name == name }?.value
    }

    /// The provider sends the user back with a code, and the state it was
    /// given unless the test says otherwise.
    func approve(code: String, state: String? = nil) {
        completion?(.success(redirect + "?code=" + code + "&state=" + (state ?? parameter("state") ?? "")))
    }

    /// The user closes the page.
    func close() {
        completion?(.failure(.canceledLogin))
    }
}

/// `ExampleSignIn`'s library with both shared host implementations: the
/// guest's `WebAuthenticationSession` and `Keychain`, the
/// `WebAuthentication` and `Secrets` contracts, `HostWebAuthentication`
/// over a browser the test plays and `HostSecrets` over a store in memory,
/// in an Embedded guest, as a native slice or through wasm2c (see
/// `Package.swift`). The same checks as `RuntimeWasm`'s WasmKit test. Part
/// of `LinkedSliceTests`, which is serialized, since both use
/// `NativeRuntime.shared`.
extension LinkedSliceTests {

    static var linksExampleSignIn: Bool {
        #if LINKED_EXAMPLESIGNIN
        true
        #else
        false
        #endif
    }

    @Test(.enabled(if: linksExampleSignIn, "Link ExampleSignIn's library first; see Packages/LinkedSlice/Package.swift"))
    func exampleSignIn() throws {
        #if LINKED_EXAMPLESIGNIN
        native.capabilities = nil
        RendererProxy.register(TestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        let store = MemorySecretStore()
        HostSecrets.reset()
        HostSecrets.store = store
        HostSecrets.work = { $0() }
        HostSecrets.deliver = { $0() }
        HostSecretsModule.register(in: native)
        let browser = LinkedSignInBrowser()
        HostWebAuthentication.reset()
        HostWebAuthentication.presenter = browser
        HostWebAuthentication.declaredSchemes = ["org.pureswift.example.signin"]
        HostWebAuthentication.deliver = { $0() }
        HostWebAuthenticationModule.register(in: native)
        defer {
            HostSecrets.reset()
            HostWebAuthentication.reset()
        }
        TestRenderer.last = nil

        #expect(native.start(rt_main, dispatch: rt_dispatch, finalize: rt_finalize) == .ok)
        let renderer = try #require(TestRenderer.last)
        func text(_ identifier: String) -> PropValue? {
            renderer.screen?.identified(identifier)?.props["text"]
        }
        func tap(_ title: String) throws {
            renderer.send(try #require(renderer.screen?.button(title)), .tap)
        }
        func token() -> String? {
            (try? store.value(forKey: "account.token")).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
        }

        // The app looked in the keychain and found nothing.
        #expect(text("status") == "Signed out" && text("token") == "No token")

        // Signing in shows the provider's page in the browser, with the
        // redirect the host gave.
        try tap("Sign In")
        #expect(text("status") == "Signing in" && renderer.screen?.button("Cancel") != nil)
        #expect(browser.pages == 1 && !browser.ephemeral)
        #expect(browser.url.hasPrefix("https://id.example.com/authorize?response_type=code&client_id=example&redirect_uri="))
        #expect(browser.redirect == "org.pureswift.example.signin:/oauth")
        #expect(browser.parameter("redirect_uri") == "org.pureswift.example.signin%3A%2Foauth", "the provider is told the same redirect")
        let state = try #require(browser.parameter("state"))
        #expect(!state.isEmpty)

        // The provider sends the user back. The app checks the reply and
        // keeps what it was given, for a background task to read.
        browser.approve(code: "code-123")
        #expect(text("status") == "Signed in" && text("token") == "A token is kept")
        #expect(token() == "code-123" && store.accessibility(forKey: "account.token") == .afterFirstUnlock)
        #expect(renderer.screen?.button("Sign Out") != nil && renderer.screen?.button("Sign In") == nil)

        // Signing out removes it.
        try tap("Sign Out")
        #expect(text("status") == "Signed out" && token() == nil)

        // A private page, which the user closes.
        try tap("Sign In Privately")
        #expect(browser.pages == 2 && browser.ephemeral)
        #expect(browser.parameter("state") != state, "each request has its own")
        browser.close()
        #expect(text("status") == "Sign-in cancelled" && token() == nil)

        // A reply that isn't to this request is refused by the app: the
        // host read none of it.
        try tap("Sign In")
        browser.approve(code: "stolen", state: "someone-elses")
        #expect(text("status") == "The reply didn't match the request" && token() == nil)

        // The app closes the page itself.
        try tap("Sign In")
        try tap("Cancel")
        #expect(text("status") == "Sign-in cancelled" && browser.cancels == 1)
        browser.approve(code: "late")
        #expect(token() == nil, "what the browser says afterwards is ignored")

        // A keychain that can't be read now.
        try tap("Sign In")
        store.failure = .unavailable
        browser.approve(code: "code-456")
        #expect(text("status") == "The keychain can't be read now" && text("token") == "No token")
        try tap("Sign In")
        browser.approve(code: "code-789")
        #expect(text("status") == "Signed in" && token() == "code-789")
        #expect(try store.keys() == ["account.token"])
        #endif
    }
}
