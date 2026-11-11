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
/// contracts or callbacks, `RawRepresentable` types with `String` raw values,
/// optionals of object types, and arrays of `String`, contracts, callbacks or
/// raw string types. A static method returning `Self` is a constructor.
///
/// A raw string type travels as its `rawValue`. A method returning one must be
/// declared `throws`: if the host's string isn't a valid raw value, the call
/// throws `RuntimeError.thrown`.
@attached(peer, names: suffixed(Proxy), prefixed(_rt_contract_), named(_rtEncode), named(_rtDecodeRetained), named(_rtDecodeBorrowed), named(_rtResult))
public macro DynamicRuntime(
    _ name: StaticString,
    version: UInt32 = 1,
    requires capability: Capability? = nil
) = #externalMacro(module: "DynamicRuntimeMacros", type: "DynamicRuntimeMacro")

/// Declares a callback interface: a protocol the caller implements and
/// passes to native code, which calls back through `rt_dispatch` (§6.2).
///
/// Same rules as `@DynamicRuntime`, without static methods.
@attached(peer, names: suffixed(Proxy), prefixed(_rt_contract_), named(_rtEncode), named(_rtDecodeRetained), named(_rtDecodeBorrowed), named(_rtResult))
public macro DynamicCallback(
    _ name: StaticString,
    version: UInt32 = 1
) = #externalMacro(module: "DynamicRuntimeMacros", type: "DynamicCallbackMacro")
