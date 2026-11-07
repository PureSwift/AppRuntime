import RuntimeABI

/// A lazily resolved `rt_class` lookup, cached after the first use.
///
/// Generated proxies keep one per contract in a static property. The guest
/// is single-threaded (§6.4), so the cache needs no synchronization.
public final class ClassReference: @unchecked Sendable {

    /// Contract or native class name.
    public let name: StaticString

    private var resolved: ClassID?

    public init(_ name: StaticString) {
        self.name = name
    }

    /// The class ID, or `0` if the host doesn't provide the class.
    public var id: ClassID {
        if let resolved {
            return resolved
        }
        let id = Runtime.lookupClass(name)
        // Don't cache a miss: the host may register the class later.
        if id != 0 {
            resolved = id
        }
        return id
    }

    /// Whether the host provides this class.
    public var isAvailable: Bool {
        id != 0
    }
}

/// A lazily resolved `rt_method` lookup, cached after the first use.
public final class MethodReference: @unchecked Sendable {

    /// Class the method belongs to.
    public let owner: ClassReference

    /// Portable method key.
    public let key: StaticString

    /// Wire signature.
    public let signature: StaticString

    /// Instance, static or constructor.
    public let kind: MethodKind

    private var resolved: MethodID?

    public init(_ owner: ClassReference, _ key: StaticString, _ signature: StaticString, _ kind: MethodKind = .instance) {
        self.owner = owner
        self.key = key
        self.signature = signature
        self.kind = kind
    }

    /// The method ID, or `0` if the host doesn't provide the method (for
    /// example, a method added in a later contract version).
    public var id: MethodID {
        if let resolved {
            return resolved
        }
        let id = Runtime.lookupMethod(owner.id, key: key, signature: signature, kind: kind)
        if id != 0 {
            resolved = id
        }
        return id
    }

    /// Whether the host provides this method, like `respondsToSelector:`.
    public var isAvailable: Bool {
        id != 0
    }
}
