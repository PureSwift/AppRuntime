import DynamicDefaults
import DynamicFiles
import DynamicRuntime
import RuntimeABI

/// What `HostDefaults` keeps values in. A host with a store of its own
/// (`UserDefaults`, `SharedPreferences`) wraps it in one of these; others
/// use `FileDefaultsStorage`.
///
/// Called on the main thread. A key holds one value: setting a string
/// replaces bytes, and the other way around.
public protocol DefaultsStorage: AnyObject {

    func string(_ key: String) -> String?

    func data(_ key: String) -> [UInt8]?

    /// Whether the value was kept.
    func setString(_ value: String, key: String) -> Bool

    /// Whether the value was kept.
    func setData(_ value: [UInt8], key: String) -> Bool

    func remove(_ key: String)

    /// Every key with a value, in any order.
    func keys() -> [String]
}

/// The `Defaults` contract over a `DefaultsStorage`.
///
/// ```swift
/// HostDefaults.storage = try FileDefaultsStorage(path: container + "/Defaults")
/// HostDefaultsModule.register(in: runtime)
/// ```
///
/// Before `storage` is set, nothing is kept: reads find nothing and writes
/// are refused.
public final class HostDefaults: Defaults {

    nonisolated(unsafe) public static var storage: (any DefaultsStorage)?

    nonisolated(unsafe) private static let shared = HostDefaults()

    public static func standard() -> HostDefaults {
        shared
    }

    public func string(_ key: String) -> String? {
        Self.storage?.string(key)
    }

    public func data(_ key: String) -> [UInt8]? {
        Self.storage?.data(key)
    }

    public func setString(_ value: String, key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return Self.storage?.setString(value, key: key) ?? false
    }

    public func setData(_ value: [UInt8], key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return Self.storage?.setData(value, key: key) ?? false
    }

    public func remove(_ key: String) {
        Self.storage?.remove(key)
    }

    public func keys() -> [String] {
        // By their bytes, so every host gives the same order.
        (Self.storage?.keys() ?? []).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
}

/// The defaults module: `Defaults`.
public enum HostDefaultsModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [DefaultsProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        DefaultsProxy.register(HostDefaults.self, in: registrar)
    }
}

/// Settings in one file, for a host whose platform has no store of its own:
/// the Linux host, in the app's `/data`.
///
/// Every value is in memory, and each change rewrites the file atomically,
/// before the call returns. That's the right trade for a few small values;
/// it isn't a database.
///
/// The file is `"RTD1"`, then for each key, in order: a kind byte (0 a
/// string, 1 bytes), the key's length and bytes, and the value's length
/// and bytes. Lengths are 32-bit, little-endian; strings are UTF-8. A file
/// that doesn't read that way is moved aside to `<path>.corrupt`, and the
/// app starts with no settings.
public final class FileDefaultsStorage: DefaultsStorage {

    enum Value: Equatable {
        case string(String)
        case data([UInt8])
    }

    public let path: String

    /// The largest value kept, in bytes. A larger one is refused.
    public let maximumValueSize: Int

    private var values: [String: Value]

    /// Reads the file at `path`, if there's one, and makes the directory
    /// it's in.
    public init(path: String, maximumValueSize: Int = 64 << 10) throws(FileError) {
        self.path = path
        self.maximumValueSize = maximumValueSize
        try FileSystem(directories: [:], maximumTransfer: 0).makeDirectories(FileSystem.parent(path))
        guard let bytes = try FileSystem.contents(ofFile: path) else {
            values = [:]
            return
        }
        if let decoded = Self.decode(bytes) {
            values = decoded
        } else {
            // Keep what was there for whoever wants to look, out of the way.
            _ = try? FileSystem.replace(file: path + ".corrupt", with: bytes)
            values = [:]
            try save()
        }
    }

    public func string(_ key: String) -> String? {
        if case .string(let value) = values[key] {
            return value
        }
        return nil
    }

    public func data(_ key: String) -> [UInt8]? {
        if case .data(let value) = values[key] {
            return value
        }
        return nil
    }

    public func setString(_ value: String, key: String) -> Bool {
        guard value.utf8.count <= maximumValueSize else { return false }
        return store(.string(value), key)
    }

    public func setData(_ value: [UInt8], key: String) -> Bool {
        guard value.count <= maximumValueSize else { return false }
        return store(.data(value), key)
    }

    public func remove(_ key: String) {
        guard let previous = values.removeValue(forKey: key) else { return }
        if (try? save()) == nil {
            // The file still has it, so it's still set.
            values[key] = previous
        }
    }

    public func keys() -> [String] {
        Array(values.keys)
    }

    private func store(_ value: Value, _ key: String) -> Bool {
        let previous = values[key]
        guard previous != value else { return true }
        values[key] = value
        if (try? save()) == nil {
            values[key] = previous
            return false
        }
        return true
    }

    private func save() throws(FileError) {
        try FileSystem.replace(file: path, with: Self.encode(values))
    }

    // MARK: The file

    static let magic: [UInt8] = Array("RTD1".utf8)

    static func encode(_ values: [String: Value]) -> [UInt8] {
        var bytes = magic
        func append(_ field: some Collection<UInt8>) {
            let count = UInt32(field.count)
            bytes += [UInt8(count & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count >> 16 & 0xFF), UInt8(count >> 24)]
            bytes += field
        }
        // In order, so the same settings are the same file.
        for key in values.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            switch values[key] {
            case .string(let value):
                bytes.append(0)
                append(key.utf8)
                append(value.utf8)
            case .data(let value):
                bytes.append(1)
                append(key.utf8)
                append(value)
            case nil:
                break
            }
        }
        return bytes
    }

    /// `nil` for anything `encode` wouldn't have written.
    static func decode(_ bytes: [UInt8]) -> [String: Value]? {
        guard bytes.starts(with: magic) else { return nil }
        var values: [String: Value] = [:]
        var position = magic.count
        func field() -> ArraySlice<UInt8>? {
            guard position + 4 <= bytes.count else { return nil }
            let count = Int(bytes[position]) | Int(bytes[position + 1]) << 8 | Int(bytes[position + 2]) << 16 | Int(bytes[position + 3]) << 24
            position += 4
            guard count <= bytes.count - position else { return nil }
            defer { position += count }
            return bytes[position ..< position + count]
        }
        while position < bytes.count {
            let kind = bytes[position]
            position += 1
            guard let key = field().flatMap({ String(validatingUTF8Bytes: $0) }), !key.isEmpty, let value = field() else {
                return nil
            }
            switch kind {
            case 0:
                guard let string = String(validatingUTF8Bytes: value) else { return nil }
                values[key] = .string(string)
            case 1:
                values[key] = .data(Array(value))
            default:
                return nil
            }
        }
        return values
    }
}

private extension String {

    /// The string these bytes are, if they're valid UTF-8.
    init?(validatingUTF8Bytes bytes: ArraySlice<UInt8>) {
        // Decoding repairs what isn't UTF-8, so only valid bytes come back
        // out the same.
        let string = String(decoding: bytes, as: UTF8.self)
        guard string.utf8.elementsEqual(bytes) else { return nil }
        self = string
    }
}
