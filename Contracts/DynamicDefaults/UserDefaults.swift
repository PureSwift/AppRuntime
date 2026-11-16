import DynamicRuntime
#if canImport(DynamicObservation)
@_exported import DynamicObservation
#else
@_exported import Observation
#endif

/// The app's settings: Foundation's `UserDefaults`, for a guest.
///
/// ```swift
/// let defaults = UserDefaults.standard
/// defaults.set(true, forKey: "hasSeenWelcome")
/// if defaults.bool(forKey: "hasSeenWelcome") { … }
/// ```
///
/// The names follow Foundation's, and so does what a missing value reads
/// as: `false`, 0, or `nil`. Values are kept across launches by the host
/// (the `Defaults` contract), and every call answers at once.
///
/// It's observable: a view that reads a key updates when the app sets it.
/// A change made outside the app (another process, another browser tab)
/// isn't seen until the key is read again.
///
/// Numbers and booleans are stored as text, so a host's own tools show
/// something readable. It's for small values; a host may refuse one over
/// 64 KB, and `set` then returns `false`.
public final class UserDefaults: Observable, @unchecked Sendable {

    public static let standard = UserDefaults()

    private let registrar = ObservationRegistrar()

    /// The host's store, made when first used.
    private var made: (any Defaults)?

    /// Each key's place among the observed properties. 0 is the list of
    /// keys itself.
    private var indices: [String: Int] = [:]

    private static let keysIndex = 0

    public init() { }

    private var defaults: any Defaults {
        if let made {
            return made
        }
        let defaults = DefaultsProxy.standard()
        made = defaults
        return defaults
    }

    private func index(for key: String) -> Int {
        if let index = indices[key] {
            return index
        }
        let index = indices.count + 1
        indices[key] = index
        return index
    }

    // MARK: Reading

    /// The string at `key`: also how a number or a boolean was stored.
    public func string(forKey key: String) -> String? {
        registrar.access(self, propertyIndex: index(for: key))
        return defaults.string(key)
    }

    public func data(forKey key: String) -> [UInt8]? {
        registrar.access(self, propertyIndex: index(for: key))
        return defaults.data(key)
    }

    /// `false` when there's no value, or it isn't a boolean.
    public func bool(forKey key: String) -> Bool {
        Self.bool(string(forKey: key)) ?? false
    }

    /// 0 when there's no value, or it isn't a whole number that fits.
    public func integer(forKey key: String) -> Int {
        string(forKey: key).flatMap { Int($0) } ?? 0
    }

    /// 0 when there's no value, or it isn't a number.
    public func double(forKey key: String) -> Double {
        string(forKey: key).flatMap { Double($0) } ?? 0
    }

    /// Whether there's a value at `key`, of either kind.
    public func hasValue(forKey key: String) -> Bool {
        registrar.access(self, propertyIndex: index(for: key))
        return defaults.string(key) != nil || defaults.data(key) != nil
    }

    /// Every key with a value, sorted.
    public var keys: [String] {
        registrar.access(self, propertyIndex: Self.keysIndex)
        return defaults.keys()
    }

    /// A change to `key`'s value, which may also add or remove the key.
    private func mutate(_ key: String, _ change: () -> Void) {
        registrar.withMutation(of: self, propertyIndex: Self.keysIndex) {
            registrar.withMutation(of: self, propertyIndex: index(for: key), change)
        }
    }

    static func bool(_ text: String?) -> Bool? {
        switch text {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    // MARK: Writing

    /// Stores `value`, or removes the key for `nil`. Returns whether the
    /// host kept it.
    @discardableResult
    public func set(_ value: String?, forKey key: String) -> Bool {
        guard let value else {
            removeObject(forKey: key)
            return true
        }
        var kept = false
        mutate(key) {
            kept = defaults.setString(value, key: key)
        }
        return kept
    }

    /// Stores `value`, or removes the key for `nil`. Returns whether the
    /// host kept it.
    @discardableResult
    public func set(_ value: [UInt8]?, forKey key: String) -> Bool {
        guard let value else {
            removeObject(forKey: key)
            return true
        }
        var kept = false
        mutate(key) {
            kept = defaults.setData(value, key: key)
        }
        return kept
    }

    @discardableResult
    public func set(_ value: Bool, forKey key: String) -> Bool {
        set(value ? "true" : "false", forKey: key)
    }

    @discardableResult
    public func set(_ value: Int, forKey key: String) -> Bool {
        set(String(value), forKey: key)
    }

    @discardableResult
    public func set(_ value: Double, forKey key: String) -> Bool {
        set(String(value), forKey: key)
    }

    public func removeObject(forKey key: String) {
        mutate(key) {
            defaults.remove(key)
        }
    }
}
