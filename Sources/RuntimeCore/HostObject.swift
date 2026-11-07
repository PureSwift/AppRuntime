import RuntimeABI

/// An object owned by the runtime and referenced from the handle table.
///
/// Several handles may refer to one `HostObject`; the object lives as long
/// as any handle or container (a `List`) references it.
public final class HostObject {

    public enum Storage {

        /// `rt_string_new`: UTF-8 bytes.
        case string([UInt8])

        /// `rt_bytes_new`.
        case bytes([UInt8])

        /// The built-in `List` contract.
        case list(ListStorage)

        /// `rt_implement`: methods forward to a guest.
        case implemented(Implementation)
    }

    public let storage: Storage

    init(_ storage: Storage) {
        self.storage = storage
    }

    /// The UTF-8 contents of a string object.
    public var stringValue: String? {
        guard case .string(let bytes) = storage else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The contents of a byte buffer object.
    public var bytesValue: [UInt8]? {
        guard case .bytes(let bytes) = storage else { return nil }
        return bytes
    }

    /// The guest implementation behind an `rt_implement` object.
    public var implementation: Implementation? {
        guard case .implemented(let implementation) = storage else { return nil }
        return implementation
    }
}

/// Elements of a `List`. Elements may be null.
public final class ListStorage {

    public internal(set) var elements: [HostObject?] = []

    init() { }
}

/// A native object created by `rt_implement`. Its methods forward to the
/// guest through `rt_dispatch`; when it dies the guest gets `rt_finalize`.
public final class Implementation {

    public let guest: Guest

    public let context: ContextID

    /// Interfaces (contract or callback classes) it implements.
    public let interfaces: [ClassID]

    /// Declarations passed to `rt_implement`, indexed by dispatch index.
    public let methods: [(key: String, signature: Signature)]

    init(guest: Guest, context: ContextID, interfaces: [ClassID], methods: [(key: String, signature: Signature)]) {
        self.guest = guest
        self.context = context
        self.interfaces = interfaces
        self.methods = methods
    }

    deinit {
        guest.finalize(context: context)
    }

    /// The dispatch index of the declaration matching `key` and `signature`.
    func index(key: String, signature: Signature) -> UInt32? {
        for (index, method) in methods.enumerated() where method.key == key {
            return method.signature == signature ? UInt32(index) : nil
        }
        return nil
    }
}
