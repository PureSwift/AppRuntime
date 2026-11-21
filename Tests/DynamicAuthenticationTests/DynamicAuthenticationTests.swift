import Testing
import DynamicAuthentication
import DynamicRuntime
import RuntimeCore
import RuntimeNative

/// A host's sign-in that only writes down what it's asked, and keeps the
/// callbacks for the test to answer.
final class ScriptedAuthentication: WebAuthentication {

    /// The one object, as a host has: the guest keeps what it's given.
    nonisolated(unsafe) static let instance = ScriptedAuthentication()

    var calls: [String] = []

    var callbacks: [any WebAuthenticationCallback] = []

    static func shared() -> ScriptedAuthentication { instance }

    func redirectURL(_ scheme: String, path: String) -> String {
        calls.append("redirectURL \(scheme) \(path)")
        return "https://app.example/auth/\(scheme)/\(path)"
    }

    func authenticate(_ url: String, redirect: String, ephemeral: Bool, callback: any WebAuthenticationCallback) {
        calls.append("authenticate \(url) \(redirect) \(ephemeral)")
        callbacks.append(callback)
    }

    func cancel() {
        calls.append("cancel")
    }
}

/// Serialized: the tests share the native runtime and the scripted host.
@Suite(.serialized) final class DynamicAuthenticationTests {

    let host = ScriptedAuthentication.instance

    let session = WebAuthenticationSession()

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        WebAuthenticationProxy.register(ScriptedAuthentication.self, in: native)
        WebAuthenticationCallbackProxy.registerInterface(in: native)
        host.calls = []
        host.callbacks = []
    }

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    @Test func signInNeedsNoCapability() {
        let authentication = WebAuthenticationProxy.descriptor
        #expect(authentication.name == "org.pureswift.authentication.WebAuthentication")
        #expect(authentication.capability == nil)
        #expect(method(authentication, "redirectURL:path:")?.signature == Signature("(OO)O"))
        #expect(method(authentication, "authenticate:redirect:ephemeral:callback:")?.signature == Signature("(OOZO)V"))
        #expect(method(authentication, "cancel")?.signature == Signature("()V"))
        #expect(authentication.methods.count == 4)

        let callback = WebAuthenticationCallbackProxy.descriptor
        #expect(callback.name == "org.pureswift.authentication.Callback" && callback.kind == .callback)
        #expect(method(callback, "didAuthenticate:")?.signature == Signature("(O)V"))
        #expect(callback.methods.count == 2)

        let descriptors = [authentication, callback]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
        #expect(WebAuthenticationError.canceledLogin.rawValue == 1 && WebAuthenticationError.unsupported.rawValue == 5)
    }

    @Test func theSessionAsksTheHost() {
        #expect(session.redirectURL(scheme: "org.example.app", path: "oauth") == "https://app.example/auth/org.example.app/oauth")
        #expect(session.redirectURL(scheme: "org.example.app") == "https://app.example/auth/org.example.app/", "the host says, whatever it is")
        session.authenticate(using: "https://id.example/authorize", redirect: "org.example.app:/oauth") { _ in }
        session.authenticate(using: "https://id.example/authorize", redirect: "r", preferredBrowserSession: .ephemeral) { _ in }
        session.cancel()
        #expect(host.calls == [
            "redirectURL org.example.app oauth", "redirectURL org.example.app ",
            "authenticate https://id.example/authorize org.example.app:/oauth false",
            "authenticate https://id.example/authorize r true", "cancel",
        ])
    }

    @Test func aSignInAnswersOnce() {
        var results: [Result<String, WebAuthenticationError>] = []
        for _ in 0..<3 {
            session.authenticate(using: "https://id.example/authorize", redirect: "r") { results.append($0) }
        }
        host.callbacks[0].didAuthenticate("org.example.app:/oauth?code=1&state=2")
        host.callbacks[0].didFail(WebAuthenticationError.canceledLogin.rawValue)
        host.callbacks[1].didFail(WebAuthenticationError.canceledLogin.rawValue)
        host.callbacks[2].didFail(99)
        #expect(results.count == 3, "only a host's first answer counts")
        #expect((try? results[0].get()) == "org.example.app:/oauth?code=1&state=2", "the whole redirect")
        if case .failure(let error) = results[1] { #expect(error == .canceledLogin) } else { Issue.record("a closed page signed in") }
        if case .failure(let error) = results[2] { #expect(error == .unknown, "an error from a newer host") } else { Issue.record("a failure signed in") }
    }
}
