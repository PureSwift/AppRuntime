import CRuntime
import RuntimeABI

/// Swift wrappers over the `rt_*` imports.
///
/// In a wasm32 guest these calls are wasm imports from module `rt`; in a
/// native slice they are C symbols resolved against the host's runtime
/// library. Nothing here depends on the mode.
public enum Runtime {

    // MARK: Lookup

    /// Resolves a contract or native class name. Returns `0` if missing or
    /// refused (for example, a capability the app didn't declare).
    public static func lookupClass(_ name: StaticString) -> ClassID {
        name.withCString { pointer, count in
            rt_class(pointer, count)
        }
    }

    /// Resolves a contract or native class name. Returns `0` if missing.
    public static func lookupClass(_ name: String) -> ClassID {
        var name = name
        return name.withUTF8 { buffer in
            rt_class(buffer.cString, buffer.count)
        }
    }

    /// Resolves a method. Returns `0` if the host doesn't provide it.
    public static func lookupMethod(
        _ cls: ClassID,
        key: StaticString,
        signature: StaticString,
        kind: MethodKind
    ) -> MethodID {
        guard cls != 0 else { return 0 }
        return key.withCString { keyPointer, keyCount in
            signature.withCString { signaturePointer, signatureCount in
                rt_method(cls, keyPointer, keyCount, signaturePointer, signatureCount, kind.rawValue)
            }
        }
    }

    // MARK: Calls

    /// Invokes a method with raw slots.
    ///
    /// Returned objects are +1 and owned by the caller.
    public static func call(
        _ target: ObjectHandle,
        _ method: MethodID,
        arguments: [Slot],
        results: inout [Slot]
    ) -> RuntimeStatus {
        let status = arguments.withUnsafeBufferPointer { arguments in
            results.withUnsafeMutableBufferPointer { results in
                rt_call(
                    target,
                    method,
                    arguments.baseAddress,
                    UInt32(truncatingIfNeeded: arguments.count),
                    results.baseAddress,
                    UInt32(truncatingIfNeeded: results.count)
                )
            }
        }
        return RuntimeStatus(code: status.rawValue)
    }

    /// Converts a failed status into an error, reading the host's message for
    /// `.thrown`.
    public static func error(for status: RuntimeStatus) -> RuntimeError? {
        guard status != .ok else { return nil }
        return RuntimeError(status: status, message: status == .thrown ? takeErrorMessage() : "")
    }

    /// Reads and clears the message for the last `RT_ERR_THROWN`.
    public static func takeErrorMessage() -> String {
        let length = rt_error_message(nil, 0)
        guard length > 0 else { return "" }
        let bytes = [UInt8](unsafeUninitializedCapacity: length) { buffer, initialized in
            let copied = rt_error_message(buffer.cString, length)
            initialized = Swift.min(copied, length)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Reference counting

    public static func retain(_ handle: ObjectHandle) {
        if handle != 0 {
            rt_retain(handle)
        }
    }

    public static func release(_ handle: ObjectHandle) {
        if handle != 0 {
            rt_release(handle)
        }
    }

    /// Identity test. Handles are not unique per object.
    public static func same(_ a: ObjectHandle, _ b: ObjectHandle) -> Bool {
        rt_same(a, b) != 0
    }

    /// Type test against a class or interface.
    public static func isInstance(_ handle: ObjectHandle, of cls: ClassID) -> Bool {
        guard handle != 0, cls != 0 else { return false }
        return rt_is_instance(handle, cls) != 0
    }

    // MARK: Strings and bytes

    /// Creates a host string. Returns a +1 handle.
    public static func makeString(_ string: String) -> ObjectHandle {
        var string = string
        return string.withUTF8 { buffer in
            rt_string_new(buffer.cString, buffer.count)
        }
    }

    /// Copies a host string out. `0` reads as the empty string.
    public static func string(_ handle: ObjectHandle) -> String {
        guard handle != 0 else { return "" }
        let length = rt_string_utf8(handle, nil, 0)
        guard length > 0 else { return "" }
        let bytes = [UInt8](unsafeUninitializedCapacity: length) { buffer, initialized in
            let copied = rt_string_utf8(handle, buffer.cString, length)
            initialized = Swift.min(copied, length)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Creates a host byte buffer. Returns a +1 handle.
    public static func makeBytes(_ bytes: [UInt8]) -> ObjectHandle {
        bytes.withUnsafeBytes { buffer in
            rt_bytes_new(buffer.baseAddress, buffer.count)
        }
    }

    /// Copies a host byte buffer out. `0` reads as empty.
    public static func bytes(_ handle: ObjectHandle) -> [UInt8] {
        guard handle != 0 else { return [] }
        let length = rt_bytes_read(handle, nil, 0)
        guard length > 0 else { return [] }
        return [UInt8](unsafeUninitializedCapacity: length) { buffer, initialized in
            let copied = rt_bytes_read(handle, UnsafeMutableRawPointer(buffer.baseAddress), length)
            initialized = Swift.min(copied, length)
        }
    }
}

// MARK: - C string helpers

extension StaticString {

    /// Calls `body` with the literal's UTF-8 bytes as a C pointer and count.
    func withCString<R>(_ body: (UnsafePointer<CChar>, Int) -> R) -> R {
        precondition(hasPointerRepresentation, "Runtime names must be string literals")
        let pointer = UnsafeRawPointer(utf8Start).assumingMemoryBound(to: CChar.self)
        return body(pointer, utf8CodeUnitCount)
    }
}

extension UnsafeBufferPointer where Element == UInt8 {

    var cString: UnsafePointer<CChar>? {
        baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }
    }
}

extension UnsafeMutableBufferPointer where Element == UInt8 {

    var cString: UnsafeMutablePointer<CChar>? {
        baseAddress.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: CChar.self) }
    }
}
