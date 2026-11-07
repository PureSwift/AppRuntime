import RuntimeABI

/// The code on the other side of the ABI: a native slice, a wasm instance,
/// or host code calling `rt_*` like a native guest.
///
/// The runtime calls a guest back through `rt_dispatch` for objects it
/// created with `rt_implement`, and through `rt_finalize` when they die.
public protocol Guest: AnyObject {

    /// Capabilities this guest may use. `nil` means unrestricted. Classes
    /// whose contract requires a capability outside this set resolve to `0`.
    var capabilities: Set<Capability>? { get }

    /// `rt_dispatch`. Object arguments are borrowed; object results are +1.
    func dispatch(
        context: ContextID,
        index: UInt32,
        target: ObjectHandle,
        arguments: UnsafeBufferPointer<Slot>,
        results: UnsafeMutableBufferPointer<Slot>
    ) -> RuntimeStatus

    /// `rt_finalize`.
    func finalize(context: ContextID)
}

/// Handles the static and constructor methods of a contract implemented
/// with the Swift-registry backend. `index` is the position among the
/// contract's static and constructor methods. Object arguments are
/// borrowed; object results must be +1.
public typealias StaticImplementation = (
    _ index: UInt32,
    _ arguments: UnsafeBufferPointer<Slot>,
    _ results: UnsafeMutableBufferPointer<Slot>
) throws(RuntimeError) -> Void
