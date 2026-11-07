import CRuntime
import DynamicRuntime
import RuntimeABI
import RuntimeCore

/// Native code in this process, reached through the `rt_dispatch` and
/// `rt_finalize` C symbols.
///
/// That covers a linked native slice and host Swift code alike: both export
/// Swift objects through `DynamicRuntime`, which defines those symbols and
/// shares one context registry.
public final class NativeGuest: Guest {

    public var capabilities: Set<Capability>?

    /// Strong: Embedded Swift has no `unowned`. The runtime reaches this
    /// guest only through live `rt_implement` objects, so there is no
    /// lasting cycle.
    private let runtime: HostRuntime

    init(runtime: HostRuntime, capabilities: Set<Capability>? = nil) {
        self.runtime = runtime
        self.capabilities = capabilities
    }

    public func dispatch(
        context: ContextID,
        index: UInt32,
        target: ObjectHandle,
        arguments: UnsafeBufferPointer<Slot>,
        results: UnsafeMutableBufferPointer<Slot>
    ) -> RuntimeStatus {
        let status = rt_dispatch(
            context,
            index,
            target,
            arguments.baseAddress,
            UInt32(truncatingIfNeeded: arguments.count),
            results.baseAddress,
            UInt32(truncatingIfNeeded: results.count)
        )
        let result = RuntimeStatus(code: status.rawValue)
        // Same process: carry the thrown message across, which rt.h can't.
        if result == .thrown, let message = Exported.takeDispatchErrorMessage() {
            runtime.setError(message)
        }
        return result
    }

    public func finalize(context: ContextID) {
        rt_finalize(context)
    }
}
