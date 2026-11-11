import CRuntime
import RuntimeABI

/// How `Runtime` and `Exported` reach the runtime core.
///
/// Guests use `CRuntimeBinding`, the default: the `rt_*` imports, which are
/// wasm imports in a wasm32 guest and C symbols in a native slice.
///
/// A host that links an app's native slice uses a direct binding to its
/// in-process `HostRuntime` (`NativeRuntime.bindDirectly()`) instead. The
/// slice owns the C `rt_dispatch` and `rt_finalize`, so the host's own
/// proxies and exports must not go through the C symbols: the runtime would
/// take them for the app's.
///
/// Class-bound, because Embedded Swift only has existentials of class-bound
/// protocols. Single-threaded by contract (§6.4).
public protocol RuntimeBinding: AnyObject {

    /// `rt_class`.
    func lookupClass(_ name: UnsafeRawBufferPointer) -> ClassID

    /// `rt_method`.
    func lookupMethod(
        _ cls: ClassID,
        key: UnsafeRawBufferPointer,
        signature: UnsafeRawBufferPointer,
        kind: MethodKind
    ) -> MethodID

    /// `rt_call`. Object arguments are borrowed; object results are +1.
    func call(
        _ target: ObjectHandle,
        _ method: MethodID,
        arguments: UnsafeBufferPointer<Slot>,
        results: UnsafeMutableBufferPointer<Slot>
    ) -> RuntimeStatus

    /// `rt_error_message`: reads and clears the message for the last
    /// `RT_ERR_THROWN`.
    func takeErrorMessage() -> String

    /// `rt_retain`.
    func retain(_ handle: ObjectHandle)

    /// `rt_release`.
    func release(_ handle: ObjectHandle)

    /// `rt_same`.
    func same(_ a: ObjectHandle, _ b: ObjectHandle) -> Bool

    /// `rt_is_instance`.
    func isInstance(_ handle: ObjectHandle, of cls: ClassID) -> Bool

    /// `rt_string_new`. Returns a +1 handle.
    func makeString(utf8: UnsafeRawBufferPointer) -> ObjectHandle

    /// `rt_string_utf8`: the whole string.
    func stringUTF8(_ handle: ObjectHandle) -> [UInt8]

    /// `rt_bytes_new`. Returns a +1 handle.
    func makeBytes(_ bytes: UnsafeRawBufferPointer) -> ObjectHandle

    /// `rt_bytes_read`: the whole buffer.
    func bytes(_ handle: ObjectHandle) -> [UInt8]

    /// `rt_implement`. Returns a +1 handle, or `0` if the runtime refused.
    func implement(
        interfaces: [ClassID],
        methods: [MethodDescriptor],
        context: ContextID
    ) -> ObjectHandle
}

extension Runtime {

    /// The binding every call goes through. Set it before the first call;
    /// handles and contexts from one binding mean nothing to another.
    nonisolated(unsafe) public static var binding: any RuntimeBinding = CRuntimeBinding()
}

/// The `rt_*` imports: wasm imports in a wasm32 guest, C symbols in a native
/// slice or in a process whose `DynamicRuntime` is the guest's.
public final class CRuntimeBinding: RuntimeBinding {

    public init() { }

    public func lookupClass(_ name: UnsafeRawBufferPointer) -> ClassID {
        rt_class(name.cString, name.count)
    }

    public func lookupMethod(
        _ cls: ClassID,
        key: UnsafeRawBufferPointer,
        signature: UnsafeRawBufferPointer,
        kind: MethodKind
    ) -> MethodID {
        rt_method(cls, key.cString, key.count, signature.cString, signature.count, kind.rawValue)
    }

    public func call(
        _ target: ObjectHandle,
        _ method: MethodID,
        arguments: UnsafeBufferPointer<Slot>,
        results: UnsafeMutableBufferPointer<Slot>
    ) -> RuntimeStatus {
        let status = rt_call(
            target,
            method,
            arguments.baseAddress,
            UInt32(truncatingIfNeeded: arguments.count),
            results.baseAddress,
            UInt32(truncatingIfNeeded: results.count)
        )
        return RuntimeStatus(code: status.rawValue)
    }

    public func takeErrorMessage() -> String {
        let length = rt_error_message(nil, 0)
        guard length > 0 else { return "" }
        let bytes = [UInt8](unsafeUninitializedCapacity: length) { buffer, initialized in
            let copied = rt_error_message(buffer.cString, length)
            initialized = Swift.min(copied, length)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public func retain(_ handle: ObjectHandle) {
        rt_retain(handle)
    }

    public func release(_ handle: ObjectHandle) {
        rt_release(handle)
    }

    public func same(_ a: ObjectHandle, _ b: ObjectHandle) -> Bool {
        rt_same(a, b) != 0
    }

    public func isInstance(_ handle: ObjectHandle, of cls: ClassID) -> Bool {
        rt_is_instance(handle, cls) != 0
    }

    public func makeString(utf8: UnsafeRawBufferPointer) -> ObjectHandle {
        rt_string_new(utf8.cString, utf8.count)
    }

    public func stringUTF8(_ handle: ObjectHandle) -> [UInt8] {
        let length = rt_string_utf8(handle, nil, 0)
        guard length > 0 else { return [] }
        return [UInt8](unsafeUninitializedCapacity: length) { buffer, initialized in
            let copied = rt_string_utf8(handle, buffer.cString, length)
            initialized = Swift.min(copied, length)
        }
    }

    public func makeBytes(_ bytes: UnsafeRawBufferPointer) -> ObjectHandle {
        rt_bytes_new(bytes.baseAddress, bytes.count)
    }

    public func bytes(_ handle: ObjectHandle) -> [UInt8] {
        let length = rt_bytes_read(handle, nil, 0)
        guard length > 0 else { return [] }
        return [UInt8](unsafeUninitializedCapacity: length) { buffer, initialized in
            let copied = rt_bytes_read(handle, UnsafeMutableRawPointer(buffer.baseAddress), length)
            initialized = Swift.min(copied, length)
        }
    }

    public func implement(
        interfaces: [ClassID],
        methods: [MethodDescriptor],
        context: ContextID
    ) -> ObjectHandle {
        // One buffer holds every key and signature, so the declarations can
        // point into it for the duration of the call.
        var strings = [UInt8]()
        var ranges = [(key: Range<Int>, signature: Range<Int>)]()
        for method in methods {
            let keyStart = strings.count
            strings.append(contentsOf: method.key.utf8)
            let signatureStart = strings.count
            strings.append(contentsOf: method.signature.utf8)
            ranges.append((keyStart..<signatureStart, signatureStart..<strings.count))
        }
        return strings.withUnsafeBufferPointer { buffer in
            let base = buffer.cString
            var declarations = ranges.map { range in
                rt_method_decl(
                    name: base.map { $0 + range.key.lowerBound },
                    name_len: range.key.count,
                    sig: base.map { $0 + range.signature.lowerBound },
                    sig_len: range.signature.count
                )
            }
            return interfaces.withUnsafeBufferPointer { interfaces in
                declarations.withUnsafeMutableBufferPointer { declarations in
                    rt_implement(
                        interfaces.baseAddress,
                        UInt32(truncatingIfNeeded: interfaces.count),
                        declarations.baseAddress,
                        UInt32(truncatingIfNeeded: declarations.count),
                        context
                    )
                }
            }
        }
    }
}

extension UnsafeRawBufferPointer {

    var cString: UnsafePointer<CChar>? {
        baseAddress?.assumingMemoryBound(to: CChar.self)
    }
}
