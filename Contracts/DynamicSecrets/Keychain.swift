import DynamicRuntime
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// When a secret can be read.
public enum KeychainAccessibility: Int32, Sendable {

    /// While the device is unlocked.
    case whenUnlocked = 0

    /// From the first unlock after a restart: for what a background task
    /// reads while the phone is locked.
    case afterFirstUnlock = 1
}

/// Why a secret couldn't be stored or read. No secret under a key isn't a
/// failure: a read gives `nil`.
public enum KeychainError: Int32, Error, Sendable {

    case unknown = 0

    /// Guest-side: the task waiting was cancelled. The operation may
    /// still happen. Hosts never send it.
    case cancelled = 1

    /// The store can't be read now: the device is locked, or this host
    /// has none.
    case unavailable = 2

    /// The user refused to unlock the store.
    case notAllowed = 3

    /// A key that's empty, or longer than `Keychain.maximumKeyLength`.
    case invalidKey = 4

    /// A value longer than `Keychain.maximumValueLength`.
    case tooLarge = 5

    /// Guest-side: the secret isn't a string.
    case invalidData = 6
}

/// The app's secrets, by key: a refresh token, a mail password. What
/// `UserDefaults` and files aren't for.
///
/// ```swift
/// let keychain = Keychain.default
/// try await keychain.set(token, forKey: "mail.refreshToken", accessibility: .afterFirstUnlock)
/// if let token = try await keychain.string(forKey: "mail.refreshToken") { … }
/// try await keychain.removeValue(forKey: "mail.refreshToken")
/// ```
///
/// The system keeps them encrypted. They are this app's, on this device:
/// no other app reads them, they aren't backed up or synced, and they go
/// when the app is removed.
///
/// Every call is asynchronous, since a keyring may need unlocking, and
/// each has a completion-handler form. It's guest-side only, over the
/// `Secrets` contract, which requires `.secrets` in the manifest. The
/// guest is single-threaded (§6.4).
public final class Keychain: @unchecked Sendable {

    /// The app's secrets.
    public static let `default` = Keychain()

    /// The longest key, in UTF-8 bytes.
    public static let maximumKeyLength = 255

    /// The longest value, in bytes: a token or a password, not a file.
    public static let maximumValueLength = 16 << 10

    /// The host's store, made when first used.
    private var made: (any Secrets)?

    init() { }

    private var secrets: any Secrets {
        if let made {
            return made
        }
        let secrets = SecretsProxy.shared()
        made = secrets
        return secrets
    }

    // MARK: Completion handlers

    /// Stores bytes under `key`, replacing what was there.
    public func set(_ value: [UInt8], forKey key: String, accessibility: KeychainAccessibility = .whenUnlocked, completion: @escaping (Result<Void, KeychainError>) -> Void) {
        secrets.set(key, value: value, accessibility: accessibility.rawValue, callback: Receiver.completing(completion))
    }

    /// Stores a string, as its UTF-8.
    public func set(_ value: String, forKey key: String, accessibility: KeychainAccessibility = .whenUnlocked, completion: @escaping (Result<Void, KeychainError>) -> Void) {
        set(Array(value.utf8), forKey: key, accessibility: accessibility, completion: completion)
    }

    /// The bytes under `key`, or `nil` when there are none.
    public func data(forKey key: String, completion: @escaping (Result<[UInt8]?, KeychainError>) -> Void) {
        secrets.get(key, callback: Receiver { outcome in
            if case .value(let value) = outcome {
                completion(.success(value))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// The string under `key`, or `nil` when there's none. Bytes that
    /// aren't UTF-8 fail with `invalidData`.
    public func string(forKey key: String, completion: @escaping (Result<String?, KeychainError>) -> Void) {
        data(forKey: key) { result in
            switch result {
            case .success(let bytes?):
                if let string = Self.string(bytes) {
                    completion(.success(string))
                } else {
                    completion(.failure(.invalidData))
                }
            case .success(nil):
                completion(.success(nil))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// No secret under `key` is no error.
    public func removeValue(forKey key: String, completion: @escaping (Result<Void, KeychainError>) -> Void) {
        secrets.remove(key, callback: Receiver.completing(completion))
    }

    /// Every secret of the app's.
    public func removeAll(completion: @escaping (Result<Void, KeychainError>) -> Void) {
        secrets.removeAll(Receiver.completing(completion))
    }

    /// The keys, sorted.
    public func keys(completion: @escaping (Result<[String], KeychainError>) -> Void) {
        secrets.keys(Receiver { outcome in
            if case .keys(let keys) = outcome {
                completion(.success(keys))
            } else {
                completion(.failure(outcome.error))
            }
        })
    }

    /// The string some bytes spell, when they're UTF-8.
    private static func string(_ bytes: [UInt8]) -> String? {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        let hadError = transcode(bytes.makeIterator(), from: UTF8.self, to: UTF8.self, stoppingOnError: true) {
            output.append($0)
        }
        return hadError ? nil : String(decoding: output, as: UTF8.self)
    }

    // MARK: Async

    // Each runs where it's called from, as the guest's one thread wants
    // (§6.4).

    #if !EMBEDDED_NO_CONCURRENCY
    public nonisolated(nonsending) func set(_ value: [UInt8], forKey key: String, accessibility: KeychainAccessibility = .whenUnlocked) async throws(KeychainError) {
        try await wait { self.set(value, forKey: key, accessibility: accessibility, completion: $0) }
    }

    public nonisolated(nonsending) func set(_ value: String, forKey key: String, accessibility: KeychainAccessibility = .whenUnlocked) async throws(KeychainError) {
        try await wait { self.set(value, forKey: key, accessibility: accessibility, completion: $0) }
    }

    public nonisolated(nonsending) func data(forKey key: String) async throws(KeychainError) -> [UInt8]? {
        try await wait { self.data(forKey: key, completion: $0) }
    }

    public nonisolated(nonsending) func string(forKey key: String) async throws(KeychainError) -> String? {
        try await wait { self.string(forKey: key, completion: $0) }
    }

    public nonisolated(nonsending) func removeValue(forKey key: String) async throws(KeychainError) {
        try await wait { self.removeValue(forKey: key, completion: $0) }
    }

    public nonisolated(nonsending) func removeAll() async throws(KeychainError) {
        try await wait { self.removeAll(completion: $0) }
    }

    public nonisolated(nonsending) func keys() async throws(KeychainError) -> [String] {
        try await wait { self.keys(completion: $0) }
    }

    /// Waits for a completion handler. A cancelled task stops waiting with
    /// `cancelled`; the operation itself isn't undone.
    private nonisolated(nonsending) func wait<Value>(_ start: (@escaping (Result<Value, KeychainError>) -> Void) -> Void) async throws(KeychainError) -> Value {
        try await withCallback { (callback: Callback<Value, KeychainError>) in
            start { callback.resume(with: $0) }
        } onCancel: { callback in
            callback.resume(throwing: .cancelled)
        }
    }
    #endif
}

/// What a `SecretCallback` was told.
private enum Outcome {

    case complete
    case value([UInt8]?)
    case keys([String])
    case failure(KeychainError)

    /// The failure, or `unknown` for an answer of the wrong kind.
    var error: KeychainError {
        if case .failure(let error) = self {
            return error
        }
        return .unknown
    }
}

/// One operation's callback. The host holds it until it answers.
private final class Receiver: SecretCallback {

    private var finish: ((Outcome) -> Void)?

    init(_ finish: @escaping (Outcome) -> Void) {
        self.finish = finish
    }

    /// For the operations that answer `didComplete`.
    static func completing(_ completion: @escaping (Result<Void, KeychainError>) -> Void) -> Receiver {
        Receiver { outcome in
            if case .complete = outcome {
                completion(.success(()))
            } else {
                completion(.failure(outcome.error))
            }
        }
    }

    /// Only a host's first answer counts.
    private func answer(_ outcome: Outcome) {
        guard let finish else { return }
        self.finish = nil
        finish(outcome)
    }

    func didComplete() {
        answer(.complete)
    }

    func didGet(_ value: [UInt8], found: Bool) {
        answer(.value(found ? value : nil))
    }

    func didList(_ keys: [String]) {
        answer(.keys(keys))
    }

    func didFail(_ error: Int32) {
        answer(.failure(KeychainError(rawValue: error) ?? .unknown))
    }
}
