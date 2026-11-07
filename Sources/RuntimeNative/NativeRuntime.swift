import CRuntime
import DynamicRuntime
import RuntimeABI
import RuntimeCore

/// The process-wide runtime behind the `rt_*` C symbols.
///
/// A host links an app's native slice (`libapp.a`) with this library,
/// registers its contract implementations, then calls `start(rt_main)`.
/// A wasm host can share the same `runtime` with its import shim, so host
/// objects and wasm objects live in one handle table.
public final class NativeRuntime: ContractRegistrar {

    /// The instance the `rt_*` symbols use.
    nonisolated(unsafe) public static let shared = NativeRuntime()

    public let runtime: HostRuntime

    /// Native code calling `rt_*` in this process.
    public let guest: NativeGuest

    public init(runtime: HostRuntime = HostRuntime()) {
        self.runtime = runtime
        self.guest = NativeGuest(runtime: runtime)
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

    /// The Swift object behind a handle, if native code in this process
    /// exported it with `rt_implement`. Lets host implementations recover
    /// their own objects from proxies passed back to them.
    public func swiftObject(for handle: ObjectHandle) -> AnyObject? {
        guard let implementation = runtime.object(for: handle)?.implementation,
              implementation.guest === guest else {
            return nil
        }
        return Exported.object(for: implementation.context)
    }

    /// The Swift object behind a proxy, if it was exported from this process.
    public func swiftObject(for proxy: DynamicObject) -> AnyObject? {
        swiftObject(for: proxy.handle)
    }
}
