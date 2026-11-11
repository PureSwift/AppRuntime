import CRuntime
import DynamicRuntime
import RuntimeABI
import RuntimeCore

/// Native code that calls the `rt_*` C symbols in this process: normally an
/// app's linked native slice.
///
/// The runtime calls it back through its `rt_dispatch` and `rt_finalize`
/// exports, given as `entryPoints`. With the `GuestExports` package trait on,
/// they default to `DynamicRuntime`'s, so a guest compiled into the host's
/// process (as in AppRuntime's own tests) works without them.
public final class NativeGuest: Guest {

    /// The guest's `rt_dispatch` and `rt_finalize` exports.
    public struct EntryPoints {

        /// `rt_dispatch`.
        public typealias Dispatch = @convention(c) (
            _ context: UInt32,
            _ index: UInt32,
            _ target: rt_obj,
            _ arguments: UnsafePointer<rt_slot>?,
            _ argumentCount: UInt32,
            _ results: UnsafeMutablePointer<rt_slot>?,
            _ resultCount: UInt32
        ) -> rt_status

        /// `rt_finalize`.
        public typealias Finalize = @convention(c) (_ context: UInt32) -> Void

        public var dispatch: Dispatch

        public var finalize: Finalize

        public init(dispatch: Dispatch, finalize: Finalize) {
            self.dispatch = dispatch
            self.finalize = finalize
        }
    }

    public var capabilities: Set<Capability>?

    /// The exports the runtime calls. `nil` until a host provides them,
    /// without the `GuestExports` trait; calls then fail with `.notFound`.
    public var entryPoints: EntryPoints?

    /// Strong: Embedded Swift has no `unowned`. The runtime reaches this
    /// guest only through live `rt_implement` objects, so there is no
    /// lasting cycle.
    private let runtime: HostRuntime

    init(runtime: HostRuntime, capabilities: Set<Capability>? = nil) {
        self.runtime = runtime
        self.capabilities = capabilities
        #if GuestExports
        self.entryPoints = EntryPoints(dispatch: _rt_dispatch, finalize: _rt_finalize)
        #endif
    }

    public func dispatch(
        context: ContextID,
        index: UInt32,
        target: ObjectHandle,
        arguments: UnsafeBufferPointer<Slot>,
        results: UnsafeMutableBufferPointer<Slot>
    ) -> RuntimeStatus {
        guard let entryPoints else {
            return .notFound
        }
        let status = entryPoints.dispatch(
            context,
            index,
            target,
            arguments.baseAddress,
            UInt32(truncatingIfNeeded: arguments.count),
            results.baseAddress,
            UInt32(truncatingIfNeeded: results.count)
        )
        let result = RuntimeStatus(code: status.rawValue)
        #if GuestExports
        // Same process and same `DynamicRuntime`: carry the thrown message
        // across, which rt.h can't. A sealed slice keeps its own.
        if result == .thrown, let message = Exported.takeDispatchErrorMessage() {
            runtime.setError(message)
        }
        #endif
        return result
    }

    public func finalize(context: ContextID) {
        entryPoints?.finalize(context)
    }
}

/// The host's own Swift code, when it uses the direct binding
/// (`NativeRuntime.bindDirectly()`).
///
/// Its exports are `DynamicRuntime`'s, reached through `Exported` without
/// the C symbols, so they never mix with a linked slice's: the runtime keys
/// each implementation by its guest, and each guest numbers its own
/// contexts.
public final class HostGuest: Guest {

    /// Unrestricted: capabilities gate the app, not the host.
    public var capabilities: Set<Capability>? { nil }

    /// Strong, as in `NativeGuest`.
    private let runtime: HostRuntime

    init(runtime: HostRuntime) {
        self.runtime = runtime
    }

    public func dispatch(
        context: ContextID,
        index: UInt32,
        target: ObjectHandle,
        arguments: UnsafeBufferPointer<Slot>,
        results: UnsafeMutableBufferPointer<Slot>
    ) -> RuntimeStatus {
        let status = Exported.dispatch(
            context: context,
            index: index,
            target: target,
            arguments: arguments.baseAddress,
            argumentCount: UInt32(truncatingIfNeeded: arguments.count),
            results: results.baseAddress,
            resultCount: UInt32(truncatingIfNeeded: results.count)
        )
        if status == .thrown, let message = Exported.takeDispatchErrorMessage() {
            runtime.setError(message)
        }
        return status
    }

    public func finalize(context: ContextID) {
        Exported.finalize(context: context)
    }
}
