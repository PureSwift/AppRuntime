/// A setting a view reads and writes: SwiftUI's `@AppStorage`.
///
/// ```swift
/// struct SettingsView: View {
///     @AppStorage("soundOn") var soundOn = true
///     @AppStorage("volume") var volume = 0.5
///
///     var body: some View {
///         Toggle("Sound", isOn: $soundOn)
///         Slider(value: $volume, in: 0...1)
///     }
/// }
/// ```
///
/// The value is the one in `UserDefaults` under the key, or the default
/// while there's none. Setting it stores it. Views that read it, through
/// any `@AppStorage` or `UserDefaults` itself, update when it changes.
///
/// It works for `Bool`, `Int`, `Double`, `String`, bytes, and enums whose
/// raw value is an `Int` or a `String`.
@propertyWrapper
public struct AppStorage<Value> {

    let key: String

    let defaultValue: Value

    let store: UserDefaults

    let read: (UserDefaults, String) -> Value?

    let write: (UserDefaults, String, Value) -> Void

    init(
        _ key: String, _ defaultValue: Value, _ store: UserDefaults?,
        read: @escaping (UserDefaults, String) -> Value?,
        write: @escaping (UserDefaults, String, Value) -> Void
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.store = store ?? .standard
        self.read = read
        self.write = write
    }

    public var wrappedValue: Value {
        get { read(store, key) ?? defaultValue }
        nonmutating set { write(store, key, newValue) }
    }

    public var projectedValue: Binding<Value> {
        let storage = self
        return Binding(get: { storage.wrappedValue }, set: { storage.wrappedValue = $0 })
    }
}

extension AppStorage where Value == Bool {

    public init(wrappedValue: Bool, _ key: String, store: UserDefaults? = nil) {
        self.init(key, wrappedValue, store) { store, key in
            UserDefaults.bool(store.string(forKey: key))
        } write: { store, key, value in
            store.set(value, forKey: key)
        }
    }
}

extension AppStorage where Value == Int {

    public init(wrappedValue: Int, _ key: String, store: UserDefaults? = nil) {
        self.init(key, wrappedValue, store) { store, key in
            store.string(forKey: key).flatMap { Int($0) }
        } write: { store, key, value in
            store.set(value, forKey: key)
        }
    }
}

extension AppStorage where Value == Double {

    public init(wrappedValue: Double, _ key: String, store: UserDefaults? = nil) {
        self.init(key, wrappedValue, store) { store, key in
            store.string(forKey: key).flatMap { Double($0) }
        } write: { store, key, value in
            store.set(value, forKey: key)
        }
    }
}

extension AppStorage where Value == String {

    public init(wrappedValue: String, _ key: String, store: UserDefaults? = nil) {
        self.init(key, wrappedValue, store) { store, key in
            store.string(forKey: key)
        } write: { store, key, value in
            store.set(value, forKey: key)
        }
    }
}

extension AppStorage where Value == [UInt8] {

    public init(wrappedValue: [UInt8], _ key: String, store: UserDefaults? = nil) {
        self.init(key, wrappedValue, store) { store, key in
            store.data(forKey: key)
        } write: { store, key, value in
            store.set(value, forKey: key)
        }
    }
}

extension AppStorage where Value: RawRepresentable, Value.RawValue == Int {

    /// An enum stored by its raw value. A stored number that's no case
    /// reads as the default.
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) {
        self.init(key, wrappedValue, store) { store, key in
            store.string(forKey: key).flatMap { Int($0) }.flatMap { Value(rawValue: $0) }
        } write: { store, key, value in
            store.set(value.rawValue, forKey: key)
        }
    }
}

extension AppStorage where Value: RawRepresentable, Value.RawValue == String {

    /// An enum stored by its raw value. A stored string that's no case
    /// reads as the default.
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) {
        self.init(key, wrappedValue, store) { store, key in
            store.string(forKey: key).flatMap { Value(rawValue: $0) }
        } write: { store, key, value in
            store.set(value.rawValue, forKey: key)
        }
    }
}
