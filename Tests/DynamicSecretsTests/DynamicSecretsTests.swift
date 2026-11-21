import Testing
import DynamicRuntime
import DynamicSecrets
import RuntimeCore
import RuntimeNative

/// A host's secret store that only writes down what it's asked, and keeps
/// the callbacks for the test to answer.
final class ScriptedSecrets: Secrets {

    /// The one store, as a host has: the guest keeps what it's given.
    nonisolated(unsafe) static let instance = ScriptedSecrets()

    var calls: [String] = []

    var callbacks: [any SecretCallback] = []

    static func shared() -> ScriptedSecrets { instance }

    func set(_ key: String, value: [UInt8], accessibility: Int32, callback: any SecretCallback) {
        calls.append("set \(key) \(value) \(accessibility)")
        callbacks.append(callback)
    }

    func get(_ key: String, callback: any SecretCallback) {
        calls.append("get \(key)")
        callbacks.append(callback)
    }

    func remove(_ key: String, callback: any SecretCallback) {
        calls.append("remove \(key)")
        callbacks.append(callback)
    }

    func removeAll(_ callback: any SecretCallback) {
        calls.append("removeAll")
        callbacks.append(callback)
    }

    func keys(_ callback: any SecretCallback) {
        calls.append("keys")
        callbacks.append(callback)
    }
}

/// Serialized: the tests share the native runtime and the scripted host's
/// one store.
@Suite(.serialized) final class DynamicSecretsTests {

    let host = ScriptedSecrets.instance

    let keychain = Keychain.default

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        SecretsProxy.register(ScriptedSecrets.self, in: native)
        SecretCallbackProxy.registerInterface(in: native)
        host.calls = []
        host.callbacks = []
    }

    func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
        descriptor.methods.first { $0.key == key }
    }

    func error<Value>(_ result: Result<Value, KeychainError>?) -> KeychainError? {
        if case .failure(let error)? = result { return error }
        return nil
    }

    @Test func secretsRequireTheirCapability() {
        let secrets = SecretsProxy.descriptor
        #expect(secrets.name == "org.pureswift.secrets.Secrets")
        #expect(secrets.capability == .secrets)
        #expect(method(secrets, "set:value:accessibility:callback:")?.signature == Signature("(OOIO)V"))
        #expect(method(secrets, "get:callback:")?.signature == Signature("(OO)V"))
        #expect(method(secrets, "removeAll:")?.signature == Signature("(O)V"))
        #expect(secrets.methods.count == 6)

        let callback = SecretCallbackProxy.descriptor
        #expect(callback.name == "org.pureswift.secrets.Callback" && callback.kind == .callback)
        #expect(method(callback, "didGet:found:")?.signature == Signature("(OZ)V"))
        #expect(method(callback, "didFail:")?.signature == Signature("(I)V"))
        #expect(callback.methods.count == 4)

        let descriptors = [secrets, callback]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
        #expect(Keychain.maximumKeyLength == 255 && Keychain.maximumValueLength == 16384)
        #expect(KeychainAccessibility.whenUnlocked.rawValue == 0 && KeychainAccessibility.afterFirstUnlock.rawValue == 1)
    }

    @Test func theKeychainAsksTheHost() {
        keychain.set("tok", forKey: "mail.token") { _ in }
        keychain.set([1, 2, 255], forKey: "raw", accessibility: .afterFirstUnlock) { _ in }
        keychain.string(forKey: "mail.token") { _ in }
        keychain.data(forKey: "raw") { _ in }
        keychain.removeValue(forKey: "mail.token") { _ in }
        keychain.removeAll { _ in }
        keychain.keys { _ in }
        #expect(host.calls == [
            "set mail.token [116, 111, 107] 0", "set raw [1, 2, 255] 1", "get mail.token", "get raw",
            "remove mail.token", "removeAll", "keys",
        ], "a string is stored as its UTF-8, readable when unlocked unless it says")
    }

    @Test func noSecretIsNotAnError() {
        var strings: [Result<String?, KeychainError>] = []
        var datas: [Result<[UInt8]?, KeychainError>] = []
        keychain.string(forKey: "a") { strings.append($0) }
        keychain.string(forKey: "b") { strings.append($0) }
        keychain.string(forKey: "c") { strings.append($0) }
        keychain.data(forKey: "c") { datas.append($0) }
        keychain.data(forKey: "d") { datas.append($0) }

        host.callbacks[0].didGet(Array("pässword".utf8), found: true)
        host.callbacks[0].didFail(0)
        host.callbacks[1].didGet([], found: false)
        host.callbacks[2].didGet([0xFF, 0xFE], found: true)
        host.callbacks[3].didGet([0xFF, 0xFE], found: true)
        host.callbacks[4].didGet([9, 9], found: false)
        #expect(strings.count == 3, "only a host's first answer counts")
        #expect((try? strings[0].get()) == "pässword")
        if case .success(let none) = strings[1] { #expect(none == nil) } else { Issue.record("no secret was a failure") }
        #expect(error(strings[2]) == .invalidData, "bytes that aren't a string")
        #expect((try? datas[0].get()) == [0xFF, 0xFE], "are still bytes")
        if case .success(let none) = datas[1] { #expect(none == nil, "not found, whatever came with it") } else { Issue.record("no secret was a failure") }
    }

    @Test func answersSayHowItWent() {
        var results: [Result<Void, KeychainError>] = []
        var lists: [Result<[String], KeychainError>] = []
        keychain.set("x", forKey: "k") { results.append($0) }
        keychain.removeValue(forKey: "k") { results.append($0) }
        keychain.removeAll { results.append($0) }
        keychain.set("x", forKey: "k") { results.append($0) }
        keychain.keys { lists.append($0) }
        keychain.keys { lists.append($0) }
        host.callbacks[0].didComplete()
        host.callbacks[1].didFail(KeychainError.notAllowed.rawValue)
        host.callbacks[2].didFail(99)
        host.callbacks[3].didList(["odd"])
        host.callbacks[4].didList(["a", "b"])
        host.callbacks[5].didFail(KeychainError.unavailable.rawValue)
        #expect(error(results[0]) == nil && error(results[1]) == .notAllowed)
        #expect(error(results[2]) == .unknown, "an error from a newer host")
        #expect(error(results[3]) == .unknown, "an answer of the wrong kind")
        #expect((try? lists[0].get()) == ["a", "b"] && error(lists[1]) == .unavailable)
    }
}
