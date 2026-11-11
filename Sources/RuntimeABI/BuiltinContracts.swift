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

    /// `Permissions`: one way to ask for any capability (§7.4). Contracts
    /// keep their own `request…` methods for contract-specific options.
    public static let permissionsName = "org.pureswift.runtime.Permissions"

    /// `PermissionsDelegate`: the result of a `Permissions` request.
    public static let permissionsDelegateName = "org.pureswift.runtime.PermissionsDelegate"

    public static let permissions = ContractDescriptor(
        name: permissionsName,
        kind: .contract,
        version: 1,
        methods: [
            // A `PermissionStatus` raw value for a `Capability` raw value.
            // Never prompts.
            MethodDescriptor("status:", "(O)I", .static),
            // Asks for a capability, prompting if needed; the result arrives
            // through the delegate, which the host holds until then.
            MethodDescriptor("request:delegate:", "(OO)V", .static),
        ]
    )

    public static let permissionsDelegate = ContractDescriptor(
        name: permissionsDelegateName,
        kind: .callback,
        version: 1,
        methods: [
            MethodDescriptor("didRequest:status:", "(OI)V"),
        ]
    )

    /// `Bundle`: the app's metadata and localized strings. The guest reads
    /// them through the host, never from files (§7.4).
    public static let bundleName = "org.pureswift.runtime.Bundle"

    public static let bundle = ContractDescriptor(
        name: bundleName,
        kind: .contract,
        version: 1,
        methods: [
            MethodDescriptor("identifier", "()O", .static),
            MethodDescriptor("version", "()O", .static),
            MethodDescriptor("build", "()O", .static),
            // The user's languages, most preferred first.
            MethodDescriptor("preferredLanguages", "()O", .static),
            // A string from the bundle's tables for the user's language;
            // `nil` when there's none.
            MethodDescriptor("localizedString:table:", "(OO)O", .static),
        ]
    )

    /// `Application`: the app's lifecycle and incoming URLs.
    public static let applicationName = "org.pureswift.runtime.Application"

    /// `ApplicationDelegate`: lifecycle events and URLs, from the host.
    public static let applicationDelegateName = "org.pureswift.runtime.ApplicationDelegate"

    public static let application = ContractDescriptor(
        name: applicationName,
        kind: .contract,
        version: 1,
        methods: [
            MethodDescriptor("make:", "(O)O", .constructor),
            // An `ApplicationState` raw value.
            MethodDescriptor("state", "()I"),
        ]
    )

    public static let applicationDelegate = ContractDescriptor(
        name: applicationDelegateName,
        kind: .callback,
        version: 1,
        methods: [
            MethodDescriptor("didChangeState:state:", "(OI)V"),
            MethodDescriptor("didReceiveMemoryWarning:", "(O)V"),
            // Whether the app handled the URL.
            MethodDescriptor("open:url:", "(OO)Z"),
        ]
    )

    /// Every built-in descriptor.
    public static var all: [ContractDescriptor] {
        [
            list, string, bytes, clock, clockDelegate,
            permissions, permissionsDelegate, bundle, application, applicationDelegate,
        ]
    }

    /// The prefix of every built-in contract's name.
    public static let namespace = "org.pureswift.runtime."

    /// Whether `name` is a built-in contract's. Every host provides those,
    /// so apps don't list them in `rt.contracts`.
    public static func isBuiltin(_ name: String) -> Bool {
        name.utf8.starts(with: namespace.utf8)
    }
}
