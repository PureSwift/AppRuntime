import RuntimeABI

/// Declares a portable contract: a protocol implemented natively by each
/// platform (§4).
///
/// ```swift
/// @DynamicRuntime("org.pureswift.bluetooth.Central", requires: .bluetooth)
/// public protocol Central: AnyObject {
///     static func make(_ delegate: CentralDelegate) -> Self
///     func state() -> Int32
///     func scan(services: [String], allowDuplicates: Bool)
/// }
/// ```
///
/// Generates `CentralProxy`, a final class that conforms to the protocol and
/// calls through `rt_call`, plus the descriptor, the dispatch adapters used
/// to export Swift implementations, and the `rt.contracts` metadata record.
///
/// Rules (checked at compile time): the protocol is class-bound, has only
/// methods, no overloads, no generics, `async` or variadics; types are
/// `Bool`, `Int32`, `Int64`, `Float`, `Double`, `String`, `[UInt8]`, other
/// contracts or callbacks, optionals of object types, and arrays of
/// `String`, contracts or callbacks. A static method returning `Self` is a
/// constructor.
@attached(peer, names: suffixed(Proxy), prefixed(_rt_contract_))
public macro DynamicRuntime(
    _ name: StaticString,
    version: UInt32 = 1,
    requires capability: Capability? = nil
) = #externalMacro(module: "DynamicRuntimeMacros", type: "DynamicRuntimeMacro")

/// Declares a callback interface: a protocol the caller implements and
/// passes to native code, which calls back through `rt_dispatch` (§6.2).
///
/// Same rules as `@DynamicRuntime`, without static methods.
@attached(peer, names: suffixed(Proxy), prefixed(_rt_contract_))
public macro DynamicCallback(
    _ name: StaticString,
    version: UInt32 = 1
) = #externalMacro(module: "DynamicRuntimeMacros", type: "DynamicCallbackMacro")
