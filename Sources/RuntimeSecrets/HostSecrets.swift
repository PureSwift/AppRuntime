import Dispatch
import DynamicRuntime
import DynamicSecrets
import RuntimeABI
import RuntimeCore
import RuntimeHost

/// The platform's store for one app's secrets: the Keychain, the Secret
/// Service. It's called off the main thread, by one thread at a time, in
/// the order the guest asked.
///
/// A store scopes what it keeps to the app, keeps it on this device, out
/// of backups and off the user's other devices, and logs neither a value
/// nor a key. `HostSecrets` has checked each key and value before a store
/// sees it.
public protocol SecretStore: AnyObject, Sendable {

    /// Stores `value`, replacing what `key` had.
    func set(_ key: String, value: [UInt8], accessibility: KeychainAccessibility) throws(KeychainError)

    /// `nil` when there's none.
    func value(forKey key: String) throws(KeychainError) -> [UInt8]?

    /// No secret under `key` is no error.
    func remove(_ key: String) throws(KeychainError)

    func removeAll() throws(KeychainError)

    func keys() throws(KeychainError) -> [String]
}

/// Secrets in memory: for a host's tests. It isn't a store an app's
/// secrets should be in, and `HostSecrets` never uses it by itself: what
/// it holds is gone when the process ends, and was never encrypted.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {

    private let lock = DispatchQueue(label: "org.pureswift.runtime.secrets.memory")

    private var values: [String: (value: [UInt8], accessibility: KeychainAccessibility)] = [:]

    /// What the next call fails with, once: a locked device, a refusal.
    public var failure: KeychainError? {
        get { lock.sync { pending } }
        set { lock.sync { pending = newValue } }
    }

    private var pending: KeychainError?

    public init() { }

    /// How a secret was stored; `nil` when there's none.
    public func accessibility(forKey key: String) -> KeychainAccessibility? {
        lock.sync { values[key]?.accessibility }
    }

    private func attempt<Value>(_ body: () -> Value) throws(KeychainError) -> Value {
        let result: Result<Value, KeychainError> = lock.sync {
            if let pending {
                self.pending = nil
                return .failure(pending)
            }
            return .success(body())
        }
        return try result.get()
    }

    public func set(_ key: String, value: [UInt8], accessibility: KeychainAccessibility) throws(KeychainError) {
        try attempt { values[key] = (value, accessibility) }
    }

    public func value(forKey key: String) throws(KeychainError) -> [UInt8]? {
        try attempt { values[key]?.value }
    }

    public func remove(_ key: String) throws(KeychainError) {
        try attempt { values[key] = nil }
    }

    public func removeAll() throws(KeychainError) {
        try attempt { values = [:] }
    }

    public func keys() throws(KeychainError) -> [String] {
        try attempt { Array(values.keys) }
    }
}

/// The `Secrets` contract over a host's `SecretStore`: what every host
/// written in Swift shares.
///
/// It checks each key and value, runs the store off the main thread in the
/// order the guest asked, sorts the keys, and answers each callback once,
/// on the main thread.
///
/// ```swift
/// HostSecrets.store = MyKeychain(service: appIdentifier)
/// HostSecretsModule.register(in: runtime)
/// ```
///
/// Without a store every call fails with `unavailable`. There is no
/// stand-in: a secret that isn't kept safely is worse than one that isn't
/// kept. Main thread only.
public final class HostSecrets: Secrets {

    // MARK: The host's settings

    /// The platform's store, already scoped to this app.
    nonisolated(unsafe) public static var store: (any SecretStore)?

    /// Runs the store's work off the main thread. The default is a serial
    /// queue; whatever replaces it must keep the order.
    nonisolated(unsafe) public static var work: @Sendable (@escaping @Sendable () -> Void) -> Void = defaultWork

    /// Runs an answer on the main thread. The default is the main dispatch
    /// queue; a host with a loop of its own posts to that.
    nonisolated(unsafe) public static var deliver: @Sendable (@escaping @Sendable () -> Void) -> Void = defaultDeliver

    private static let queue = DispatchQueue(label: "org.pureswift.runtime.secrets")

    private static let defaultWork: @Sendable (@escaping @Sendable () -> Void) -> Void = { queue.async(execute: $0) }

    private static let defaultDeliver: @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    /// The one store. Never replaced: a guest keeps the object it first
    /// asked for.
    nonisolated(unsafe) private static let instance = HostSecrets()

    public static func shared() -> HostSecrets {
        instance
    }

    /// Forgets the store and the settings, for tests and for a host that
    /// starts the guest again.
    public static func reset() {
        store = nil
        work = defaultWork
        deliver = defaultDeliver
    }

    // MARK: Answers

    private enum Answer: Sendable {
        case complete
        case value([UInt8]?)
        case keys([String])
    }

    /// Calls `answer` with the callback, on the main thread and later.
    private static func later(_ callback: any SecretCallback, _ answer: @escaping (any SecretCallback) -> Void) {
        let held = MainThreadHeld((callback, answer))
        deliver {
            guard let (callback, answer) = held.take() else { return }
            answer(callback)
        }
    }

    /// Runs `operation` on the store, off the main thread, and answers
    /// `callback` on it.
    private func run(_ callback: any SecretCallback, _ operation: @escaping @Sendable (any SecretStore) throws(KeychainError) -> Answer) {
        guard let store = Self.store else {
            Self.later(callback) { $0.didFail(KeychainError.unavailable.rawValue) }
            return
        }
        // The callback is only touched again on the main thread, in
        // `deliver`, and released there.
        let held = MainThreadHeld(callback)
        let deliver = Self.deliver
        Self.work {
            let result: Result<Answer, KeychainError>
            do throws(KeychainError) {
                result = .success(try operation(store))
            } catch {
                result = .failure(error)
            }
            deliver {
                guard let callback = held.take() else { return }
                switch result {
                case .success(.complete):
                    callback.didComplete()
                case .success(.value(let value)):
                    callback.didGet(value ?? [], found: value != nil)
                case .success(.keys(let keys)):
                    callback.didList(keys)
                case .failure(let error):
                    callback.didFail(error.rawValue)
                }
            }
        }
    }

    /// Whether a key is one a store is given: 1 to 255 bytes.
    private func isValid(_ key: String, _ callback: any SecretCallback) -> Bool {
        let length = key.utf8.count
        guard length >= 1, length <= Keychain.maximumKeyLength else {
            Self.later(callback) { $0.didFail(KeychainError.invalidKey.rawValue) }
            return false
        }
        return true
    }

    // MARK: The contract

    public func set(_ key: String, value: [UInt8], accessibility: Int32, callback: any SecretCallback) {
        guard isValid(key, callback) else { return }
        guard value.count <= Keychain.maximumValueLength else {
            Self.later(callback) { $0.didFail(KeychainError.tooLarge.rawValue) }
            return
        }
        // An accessibility from a newer guest is the stricter one.
        let accessibility = KeychainAccessibility(rawValue: accessibility) ?? .whenUnlocked
        run(callback) { store throws(KeychainError) in
            try store.set(key, value: value, accessibility: accessibility)
            return .complete
        }
    }

    public func get(_ key: String, callback: any SecretCallback) {
        guard isValid(key, callback) else { return }
        run(callback) { store throws(KeychainError) in
            .value(try store.value(forKey: key))
        }
    }

    public func remove(_ key: String, callback: any SecretCallback) {
        guard isValid(key, callback) else { return }
        run(callback) { store throws(KeychainError) in
            try store.remove(key)
            return .complete
        }
    }

    public func removeAll(_ callback: any SecretCallback) {
        run(callback) { store throws(KeychainError) in
            try store.removeAll()
            return .complete
        }
    }

    public func keys(_ callback: any SecretCallback) {
        run(callback) { store throws(KeychainError) in
            // By UTF-8 bytes, so every host gives the same order.
            .keys(try store.keys().sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) })
        }
    }
}

/// The secrets module: the contract and its callback.
public enum HostSecretsModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [SecretsProxy.descriptor, SecretCallbackProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        SecretsProxy.register(HostSecrets.self, in: registrar)
        SecretCallbackProxy.registerInterface(in: registrar)
    }

    /// No platform asks the user before an app keeps a secret.
    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.secrets: GrantedPermission()]
    }
}
