import DynamicRuntime
import RuntimeABI
import RuntimeCore

/// Binds `DynamicRuntime` straight to a `HostRuntime`, as `guest`, without
/// the `rt_*` C symbols. A host sets it with `NativeRuntime.bindDirectly()`.
public final class DirectRuntimeBinding: RuntimeBinding {

    public let runtime: HostRuntime

    /// The guest that lookups and exports belong to.
    public let guest: Guest

    public init(runtime: HostRuntime, guest: Guest) {
        self.runtime = runtime
        self.guest = guest
    }

    public func lookupClass(_ name: UnsafeRawBufferPointer) -> ClassID {
        runtime.lookupClass(name, guest: guest)
    }

    public func lookupMethod(
        _ cls: ClassID,
        key: UnsafeRawBufferPointer,
        signature: UnsafeRawBufferPointer,
        kind: MethodKind
    ) -> MethodID {
        runtime.lookupMethod(cls, key: key, signature: signature, flags: kind.rawValue)
    }

    public func call(
        _ target: ObjectHandle,
        _ method: MethodID,
        arguments: UnsafeBufferPointer<Slot>,
        results: UnsafeMutableBufferPointer<Slot>
    ) -> RuntimeStatus {
        runtime.call(target: target, method: method, arguments: arguments, results: results)
    }

    public func takeErrorMessage() -> String {
        String(decoding: runtime.errorMessage(capacity: .max), as: UTF8.self)
    }

    public func retain(_ handle: ObjectHandle) {
        runtime.retain(handle)
    }

    public func release(_ handle: ObjectHandle) {
        runtime.release(handle)
    }

    public func same(_ a: ObjectHandle, _ b: ObjectHandle) -> Bool {
        runtime.same(a, b)
    }

    public func isInstance(_ handle: ObjectHandle, of cls: ClassID) -> Bool {
        runtime.isInstance(handle, of: cls)
    }

    public func makeString(utf8: UnsafeRawBufferPointer) -> ObjectHandle {
        runtime.makeString(utf8: utf8)
    }

    public func stringUTF8(_ handle: ObjectHandle) -> [UInt8] {
        runtime.stringUTF8(handle) ?? []
    }

    public func makeBytes(_ bytes: UnsafeRawBufferPointer) -> ObjectHandle {
        runtime.makeBytes(bytes)
    }

    public func bytes(_ handle: ObjectHandle) -> [UInt8] {
        runtime.bytes(handle) ?? []
    }

    public func implement(
        interfaces: [ClassID],
        methods: [MethodDescriptor],
        context: ContextID
    ) -> ObjectHandle {
        runtime.implement(
            interfaces: interfaces,
            methods: methods.map { (Array($0.key.utf8), Array($0.signature.utf8)) },
            context: context,
            guest: guest
        )
    }
}
