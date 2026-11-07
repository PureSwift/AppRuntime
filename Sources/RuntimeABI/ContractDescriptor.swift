/// Whether an interface is implemented by the host or by the guest.
public enum ContractKind: UInt8, Equatable, Hashable, Sendable {

    /// `@DynamicRuntime`: implemented natively by each platform.
    case contract = 1

    /// `@DynamicCallback`: implemented by the caller through `rt_implement`.
    case callback = 2
}

/// One method of a contract: its portable key, wire signature and kind.
public struct MethodDescriptor: Equatable, Hashable, Sendable {

    /// Portable selector-style key, for example `connect:timeout:`.
    public let key: String

    /// Wire signature.
    public let signature: Signature

    /// Instance, static or constructor.
    public let kind: MethodKind

    public init(key: String, signature: Signature, kind: MethodKind) {
        self.key = key
        self.signature = signature
        self.kind = kind
    }

    /// Creates a descriptor from a signature string.
    ///
    /// - Precondition: `signature` is a valid wire signature.
    public init(_ key: String, _ signature: String, _ kind: MethodKind = .instance) {
        guard let parsed = Signature(signature) else {
            preconditionFailure("Invalid wire signature")
        }
        self.init(key: key, signature: parsed, kind: kind)
    }
}

/// Everything the runtime and the packager need to know about a contract or
/// callback interface. This is what the `rt.contracts` section holds (§10).
public struct ContractDescriptor: Equatable, Hashable, Sendable {

    /// Reverse-DNS contract name, for example `org.pureswift.bluetooth.Central`.
    public let name: String

    /// Contract or callback.
    public let kind: ContractKind

    /// Contract version. Later versions may only add methods.
    public let version: UInt32

    /// Capability the contract requires, if any.
    public let capability: Capability?

    /// Methods in declaration order.
    public let methods: [MethodDescriptor]

    public init(
        name: String,
        kind: ContractKind,
        version: UInt32 = 1,
        capability: Capability? = nil,
        methods: [MethodDescriptor]
    ) {
        self.name = name
        self.kind = kind
        self.version = version
        self.capability = capability
        self.methods = methods
    }
}

public extension ContractDescriptor {

    /// Instance methods in declaration order. Their positions are the
    /// `rt_dispatch` indices for objects created with `rt_implement`.
    var instanceMethods: [MethodDescriptor] {
        methods.filter { $0.kind == .instance }
    }

    /// Static and constructor methods in declaration order. Their positions
    /// are the indices passed to a Swift-registry static implementation.
    var staticMethods: [MethodDescriptor] {
        methods.filter { $0.kind != .instance }
    }

    /// Finds a method by key and kind.
    func method(key: String, kind: MethodKind) -> MethodDescriptor? {
        methods.first { $0.key == key && $0.kind == kind }
    }
}
