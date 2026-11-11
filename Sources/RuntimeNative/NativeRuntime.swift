import CRuntime
import DynamicRuntime
import RuntimeABI
import RuntimeCore

/// The process-wide runtime behind the `rt_*` C symbols.
///
/// A host links an app's native slice (`libapp.a`) with this library, and
/// depends on AppRuntime without the `GuestExports` trait. It registers its
/// contract implementations, then starts the app with the slice's exports:
///
/// ```swift
/// let native = NativeRuntime.shared
/// native.bindDirectly()
/// MyContractProxy.register(MyImplementation.self, in: native)
/// native.start(rt_main, dispatch: rt_dispatch, finalize: rt_finalize)
/// ```
///
/// There are two guests: the app (`guest`), which the C symbols serve, and
/// the host's own Swift code (`host`), which the direct binding serves.
///
/// A wasm host can share the same `runtime` with its import shim, so host
/// objects and wasm objects live in one handle table.
public final class NativeRuntime: ContractRegistrar {

    /// The instance the `rt_*` symbols use.
    nonisolated(unsafe) public static let shared = NativeRuntime()

    public let runtime: HostRuntime

    /// Native code calling `rt_*` in this process: the app's slice.
    public let guest: NativeGuest

    /// The host's own Swift code, once it uses `bindDirectly()`.
    public let host: HostGuest

    public init(runtime: HostRuntime = HostRuntime()) {
        self.runtime = runtime
        self.guest = NativeGuest(runtime: runtime)
        self.host = HostGuest(runtime: runtime)
    }

    /// Binds this process's `DynamicRuntime` to `runtime` directly, as
    /// `host`. Call it before the host makes a proxy or exports an object.
    /// From then on the host's proxies and exports never touch the C
    /// symbols, which belong to the app.
    public func bindDirectly() {
        Runtime.binding = DirectRuntimeBinding(runtime: runtime, guest: host)
    }

    /// Capabilities native callers may use; `nil` is unrestricted. Native
    /// enforcement is advisory (§2.4): native code can bypass the runtime.
    public var capabilities: Set<Capability>? {
        get { guest.capabilities }
        set { guest.capabilities = newValue }
    }

    /// Calls the app's entry point once. The host owns `main` and the run
    /// loop; everything after this arrives through `rt_dispatch`.
    ///
    /// ```swift
    /// let status = NativeRuntime.shared.start(rt_main)
    /// ```
    @discardableResult
    public func start(_ entry: () -> rt_status) -> RuntimeStatus {
        RuntimeStatus(code: entry().rawValue)
    }

    /// Calls the entry point of an app whose `rt_dispatch` and `rt_finalize`
    /// are `dispatch` and `finalize`, normally a linked slice's.
    ///
    /// ```swift
    /// native.start(rt_main, dispatch: rt_dispatch, finalize: rt_finalize)
    /// ```
    @discardableResult
    public func start(
        _ entry: () -> rt_status,
        dispatch: NativeGuest.EntryPoints.Dispatch,
        finalize: NativeGuest.EntryPoints.Finalize
    ) -> RuntimeStatus {
        guest.entryPoints = NativeGuest.EntryPoints(dispatch: dispatch, finalize: finalize)
        return start(entry)
    }

    // MARK: ContractRegistrar

    public func register(_ descriptor: ContractDescriptor, statics: StaticMethodTable?) {
        guard let statics else {
            runtime.register(descriptor)
            return
        }
        runtime.register(descriptor) { (index: UInt32, arguments: UnsafeBufferPointer<Slot>, results: UnsafeMutableBufferPointer<Slot>) throws(RuntimeError) in
            var reader = Arguments(arguments.baseAddress, count: arguments.count)
            try statics(index, &reader, ResultWriter(results.baseAddress, count: results.count))
        }
    }

    // MARK: Host helpers

    /// The Swift object behind a handle, if this process's `DynamicRuntime`
    /// exported it. Lets host implementations recover their own objects from
    /// proxies passed back to them.
    public func swiftObject(for handle: ObjectHandle) -> AnyObject? {
        guard let implementation = runtime.object(for: handle)?.implementation else {
            return nil
        }
        if implementation.guest === host {
            return Exported.object(for: implementation.context)
        }
        #if GuestExports
        // The guest's exports are this process's too.
        if implementation.guest === guest {
            return Exported.object(for: implementation.context)
        }
        #endif
        return nil
    }

    /// The Swift object behind a proxy, if it was exported from this process.
    public func swiftObject(for proxy: DynamicObject) -> AnyObject? {
        swiftObject(for: proxy.handle)
    }
}
