import Foundation
import Testing
import DynamicRuntime
import DynamicSecrets
import RuntimeCore
import RuntimeHost
import RuntimeNative
@testable import RuntimeSecrets

/// Work the test runs when it chooses.
final class HeldSecretWork: @unchecked Sendable {

    var jobs: [@Sendable () -> Void] = []

    func runAll() {
        let waiting = jobs
        jobs = []
        for job in waiting { job() }
    }
}

/// `HostSecrets` over a store in memory, driven from the guest's
/// `Keychain` through the runtime.
///
/// Serialized: `HostSecrets` and the native runtime are shared.
@Suite(.serialized) final class RuntimeSecretsTests {

    let store = MemorySecretStore()

    let keychain = Keychain.default

    init() {
        let native = NativeRuntime.shared
        native.capabilities = nil
        HostSecrets.reset()
        HostSecrets.store = store
        HostSecrets.work = { $0() }
        HostSecrets.deliver = { $0() }
        HostSecretsModule.register(in: native)
    }

    deinit {
        HostSecrets.reset()
    }

    func set(_ value: String, _ key: String, _ accessibility: KeychainAccessibility = .whenUnlocked) -> KeychainError? {
        var result: Result<Void, KeychainError>?
        keychain.set(value, forKey: key, accessibility: accessibility) { result = $0 }
        return failure(result)
    }

    func string(_ key: String) -> Result<String?, KeychainError>? {
        var result: Result<String?, KeychainError>?
        keychain.string(forKey: key) { result = $0 }
        return result
    }

    func keys() -> Result<[String], KeychainError>? {
        var result: Result<[String], KeychainError>?
        keychain.keys { result = $0 }
        return result
    }

    func remove(_ key: String) -> KeychainError? {
        var result: Result<Void, KeychainError>?
        keychain.removeValue(forKey: key) { result = $0 }
        return failure(result)
    }

    func failure<Value>(_ result: Result<Value, KeychainError>?) -> KeychainError? {
        if case .failure(let error)? = result { return error }
        return nil
    }

    func value<Value>(_ result: Result<Value?, KeychainError>?) -> Value? {
        if case .success(let value)? = result { return value }
        return nil
    }

    @Test func moduleListsItsContracts() {
        #expect(HostSecretsModule.contracts.map(\.name) == ["org.pureswift.secrets.Secrets", "org.pureswift.secrets.Callback"])
        #expect(HostSecretsModule.permissionProviders()[.secrets]?.status() == .granted, "nothing asks before an app keeps a secret")
        #expect(HostSecrets.shared() === HostSecrets.shared())
    }

    @Test func withoutAStoreThereAreNoSecrets() {
        HostSecrets.store = nil
        #expect(set("token", "k") == .unavailable)
        #expect(failure(string("k")) == .unavailable && failure(keys()) == .unavailable)
        #expect(remove("k") == .unavailable)
        var result: Result<Void, KeychainError>?
        keychain.removeAll { result = $0 }
        #expect(failure(result) == .unavailable, "nothing is kept in memory in its place")
    }

    @Test func secretsAreKeptByKey() throws {
        #expect(value(string("mail.token")) == nil && failure(string("mail.token")) == nil, "no secret isn't an error")
        #expect(set("first", "mail.token") == nil)
        #expect(value(string("mail.token")) == "first")
        #expect(store.accessibility(forKey: "mail.token") == .whenUnlocked)
        #expect(set("second", "mail.token", .afterFirstUnlock) == nil)
        #expect(value(string("mail.token")) == "second", "replaced")
        #expect(store.accessibility(forKey: "mail.token") == .afterFirstUnlock)

        var bytes: Result<[UInt8]?, KeychainError>?
        var stored: Result<Void, KeychainError>?
        keychain.set([0, 255, 7], forKey: "key material") { stored = $0 }
        keychain.data(forKey: "key material") { bytes = $0 }
        #expect(failure(stored) == nil && value(bytes) == [0, 255, 7])
        #expect(failure(string("key material")) == .invalidData, "bytes that aren't a string")
        #expect(set("", "empty") == nil && value(string("empty")) == "", "an empty secret is still one")

        #expect(set("z", "Zebra") == nil && set("é", "éclair") == nil)
        #expect(try keys()?.get() == ["Zebra", "empty", "key material", "mail.token", "éclair"], "sorted by their bytes")

        #expect(remove("mail.token") == nil && value(string("mail.token")) == nil)
        #expect(remove("mail.token") == nil, "removing nothing is no error")
        var cleared: Result<Void, KeychainError>?
        keychain.removeAll { cleared = $0 }
        #expect(failure(cleared) == nil)
        #expect(try keys()?.get() == [])
    }

    @Test func keysAndValuesHaveLimits() throws {
        #expect(set("x", "") == .invalidKey)
        #expect(failure(string("")) == .invalidKey && remove("") == .invalidKey)
        let longest = String(repeating: "k", count: 255)
        #expect(set("x", longest) == nil && value(string(longest)) == "x")
        #expect(set("x", longest + "k") == .invalidKey)
        #expect(set("x", String(repeating: "é", count: 128)) == .invalidKey, "256 bytes, though 128 characters")

        var result: Result<Void, KeychainError>?
        keychain.set([UInt8](repeating: 1, count: 16 << 10), forKey: "big") { result = $0 }
        #expect(failure(result) == nil)
        keychain.set([UInt8](repeating: 1, count: (16 << 10) + 1), forKey: "bigger") { result = $0 }
        #expect(failure(result) == .tooLarge)
        #expect(try keys()?.get() == ["big", longest])

        // An accessibility from a newer guest is the stricter one.
        HostSecrets.shared().set("odd", value: [1], accessibility: 9, callback: Ignored())
        #expect(store.accessibility(forKey: "odd") == .whenUnlocked)
    }

    @Test func theStoresRefusalsReachTheApp() {
        #expect(set("token", "k") == nil)
        store.failure = .unavailable
        #expect(failure(string("k")) == .unavailable, "the device is locked")
        #expect(value(string("k")) == "token", "and then it isn't")
        store.failure = .notAllowed
        #expect(set("other", "k") == .notAllowed, "the user wouldn't unlock the keyring")
        #expect(value(string("k")) == "token")
        store.failure = .unavailable
        #expect(failure(keys()) == .unavailable)
        store.failure = .notAllowed
        #expect(remove("k") == .notAllowed)
    }

    @Test func theStoreIsWorkedInTheOrderAsked() {
        let held = HeldSecretWork()
        HostSecrets.work = { held.jobs.append($0) }
        var log: [String] = []
        keychain.set("one", forKey: "k") { _ in log.append("set one") }
        keychain.string(forKey: "k") { log.append("read \((try? $0.get()) ?? "nothing")") }
        keychain.set("two", forKey: "k") { _ in log.append("set two") }
        keychain.removeValue(forKey: "k") { _ in log.append("removed") }
        keychain.string(forKey: "k") { log.append("read \((try? $0.get()) ?? "nothing")") }
        #expect(log.isEmpty && held.jobs.count == 5, "nothing happens on the main thread")
        held.runAll()
        #expect(log == ["set one", "read one", "set two", "removed", "read nothing"])
    }

    // The async tests run on the main actor, with their child tasks: the
    // guest is single-threaded.

    @MainActor @Test func callsCanBeAwaited() async throws {
        HostSecrets.reset()
        HostSecrets.store = store
        try await keychain.set("awaited", forKey: "a")
        try await keychain.set([1, 2], forKey: "b", accessibility: .afterFirstUnlock)
        #expect(try await keychain.string(forKey: "a") == "awaited")
        #expect(try await keychain.data(forKey: "b") == [1, 2])
        #expect(try await keychain.string(forKey: "none") == nil)
        #expect(try await keychain.keys() == ["a", "b"])
        try await keychain.removeValue(forKey: "a")
        #expect(try await keychain.keys() == ["b"])
        try await keychain.removeAll()
        #expect(try await keychain.keys().isEmpty)
        do {
            try await keychain.set("x", forKey: "")
            Issue.record("an empty key was stored")
        } catch {
            #expect(error == .invalidKey)
        }
    }
}

/// A callback nobody listens to.
final class Ignored: SecretCallback {
    func didComplete() { }
    func didGet(_ value: [UInt8], found: Bool) { }
    func didList(_ keys: [String]) { }
    func didFail(_ error: Int32) { }
}
