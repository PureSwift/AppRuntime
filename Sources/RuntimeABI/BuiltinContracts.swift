/// Contracts every host provides (§7.4).
public enum BuiltinContracts {

    /// `List`: a host-owned ordered collection of objects. Contract
    /// parameters and results of type `[String]` / `[SomeContract]` travel
    /// as a `List`.
    public static let listName = "org.pureswift.runtime.List"

    /// Host strings created by `rt_string_new`, for `rt_is_instance`.
    public static let stringName = "org.pureswift.runtime.String"

    /// Host byte buffers created by `rt_bytes_new`, for `rt_is_instance`.
    public static let bytesName = "org.pureswift.runtime.Bytes"

    public static let list = ContractDescriptor(
        name: listName,
        kind: .contract,
        version: 1,
        methods: [
            MethodDescriptor("make", "()O", .constructor),
            MethodDescriptor("count", "()I"),
            MethodDescriptor("objectAt:", "(I)O"),
            MethodDescriptor("append:", "(O)V"),
        ]
    )

    public static let string = ContractDescriptor(name: stringName, kind: .contract, methods: [])

    public static let bytes = ContractDescriptor(name: bytesName, kind: .contract, methods: [])

    /// `Clock`: monotonic time and one-shot timers, the guest's only source
    /// of time (§5.4). Timers fire on the main thread, through
    /// `rt_dispatch`.
    public static let clockName = "org.pureswift.runtime.Clock"

    /// `ClockDelegate`: the callback a `Clock` timer fires.
    public static let clockDelegateName = "org.pureswift.runtime.ClockDelegate"

    public static let clock = ContractDescriptor(
        name: clockName,
        kind: .contract,
        version: 1,
        methods: [
            // Monotonic nanoseconds since an arbitrary start.
            MethodDescriptor("now", "()J", .static),
            // Calls `delegate.fire()` once, after at least `nanoseconds`.
            // The host holds the delegate until then.
            MethodDescriptor("after:delegate:", "(JO)V", .static),
        ]
    )

    public static let clockDelegate = ContractDescriptor(
        name: clockDelegateName,
        kind: .callback,
        version: 1,
        methods: [
            MethodDescriptor("fire", "()V"),
        ]
    )

    /// Every built-in descriptor.
    public static var all: [ContractDescriptor] {
        [list, string, bytes, clock, clockDelegate]
    }
}
