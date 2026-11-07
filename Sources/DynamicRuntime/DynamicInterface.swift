import RuntimeABI

/// Implemented by every generated proxy: the interface's metadata.
public protocol DynamicInterface: AnyObject {

    /// Contract or callback descriptor (name, version, capability, methods).
    static var descriptor: ContractDescriptor { get }

    /// The interface's lazily resolved class.
    static var classReference: ClassReference { get }
}

public extension DynamicInterface {

    /// Whether the host provides this interface.
    static var isAvailable: Bool {
        classReference.isAvailable
    }
}

/// Handles one call to a static or constructor method of a contract
/// implemented in Swift. `index` is the position among the contract's static
/// and constructor methods.
public typealias StaticMethodTable = (
    _ index: UInt32,
    _ arguments: inout Arguments,
    _ results: ResultWriter
) throws(RuntimeError) -> Void

/// A host-side registry that Swift implementations register with (the Swift
/// registry backend, §6).
///
/// Generated proxies call this from `register(_:in:)` and
/// `registerInterface(in:)`, so contract modules don't depend on any
/// particular runtime core.
public protocol ContractRegistrar: AnyObject {

    /// Registers a contract or callback interface. `statics` handles the
    /// contract's static and constructor methods, if it is implemented here.
    func register(_ descriptor: ContractDescriptor, statics: StaticMethodTable?)
}
