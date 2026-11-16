import DynamicRuntime

/// A small store of settings, kept across launches (§7.9). App code uses
/// `UserDefaults` and `@AppStorage`, which wrap this contract.
///
/// Unlike the app's files and its model store, it's synchronous: every
/// platform has a small key-value store that answers at once, the browser
/// included. It's for small values. A host may refuse a value over 64 KB,
/// and a browser keeps about 5 MB in all.
///
/// A key holds one value, a string or bytes. It needs no capability.
///
/// | Host | Backed by |
/// |---|---|
/// | iOS / macOS | `UserDefaults` |
/// | Android | `SharedPreferences` |
/// | Linux | a file in `/data`, written atomically |
/// | Browser | `localStorage`, under the app's prefix |
@DynamicRuntime("org.pureswift.data.Defaults")
public protocol Defaults: AnyObject {

    static func standard() -> Self

    /// The string at `key`; `nil` when there's none, or the value is bytes.
    func string(_ key: String) -> String?

    /// The bytes at `key`; `nil` when there are none, or the value is a
    /// string.
    func data(_ key: String) -> [UInt8]?

    /// Stores a string at `key`, replacing what was there. `false` when the
    /// host can't keep it: it's too large, or storage is full.
    func setString(_ value: String, key: String) -> Bool

    /// Stores bytes at `key`, replacing what was there. `false` when the
    /// host can't keep them.
    func setData(_ value: [UInt8], key: String) -> Bool

    /// Removes whatever is at `key`. Fine if there's nothing.
    func remove(_ key: String)

    /// Every key with a value, sorted by its UTF-8 bytes.
    func keys() -> [String]
}
