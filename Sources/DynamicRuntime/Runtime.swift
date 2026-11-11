import CRuntime
import RuntimeABI

/// Swift wrappers over the runtime's functions.
///
/// Every call goes through `Runtime.binding`. In a guest that's the `rt_*`
/// imports: wasm imports from module `rt` in a wasm32 guest, C symbols
/// resolved against the host's runtime library in a native slice. Nothing
/// here depends on the mode.
public enum Runtime {

    // MARK: Lookup

    /// Resolves a contract or native class name. Returns `0` if missing or
    /// refused (for example, a capability the app didn't declare).
    public static func lookupClass(_ name: StaticString) -> ClassID {
        name.withCString { pointer, count in
            binding.lookupClass(UnsafeRawBufferPointer(start: pointer, count: count))
        }
    }

    /// Resolves a contract or native class name. Returns `0` if missing.
    public static func lookupClass(_ name: String) -> ClassID {
        var name = name
        return name.withUTF8 { buffer in
            binding.lookupClass(UnsafeRawBufferPointer(buffer))
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
                binding.lookupMethod(
                    cls,
                    key: UnsafeRawBufferPointer(start: keyPointer, count: keyCount),
                    signature: UnsafeRawBufferPointer(start: signaturePointer, count: signatureCount),
                    kind: kind
                )
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
        arguments.withUnsafeBufferPointer { arguments in
            results.withUnsafeMutableBufferPointer { results in
                binding.call(target, method, arguments: arguments, results: results)
            }
        }
    }

    /// Converts a failed status into an error, reading the host's message for
    /// `.thrown`.
    public static func error(for status: RuntimeStatus) -> RuntimeError? {
        guard status != .ok else { return nil }
        return RuntimeError(status: status, message: status == .thrown ? takeErrorMessage() : "")
    }

    /// Reads and clears the message for the last `RT_ERR_THROWN`.
    public static func takeErrorMessage() -> String {
        binding.takeErrorMessage()
    }

    // MARK: Reference counting

    public static func retain(_ handle: ObjectHandle) {
        if handle != 0 {
            binding.retain(handle)
        }
    }

    public static func release(_ handle: ObjectHandle) {
        if handle != 0 {
            binding.release(handle)
        }
    }

    /// Identity test. Handles are not unique per object.
    public static func same(_ a: ObjectHandle, _ b: ObjectHandle) -> Bool {
        binding.same(a, b)
    }

    /// Type test against a class or interface.
    public static func isInstance(_ handle: ObjectHandle, of cls: ClassID) -> Bool {
        guard handle != 0, cls != 0 else { return false }
        return binding.isInstance(handle, of: cls)
    }

    // MARK: Strings and bytes

    /// Creates a host string. Returns a +1 handle.
    public static func makeString(_ string: String) -> ObjectHandle {
        var string = string
        return string.withUTF8 { buffer in
            binding.makeString(utf8: UnsafeRawBufferPointer(buffer))
        }
    }

    /// Copies a host string out. `0` reads as the empty string.
    public static func string(_ handle: ObjectHandle) -> String {
        guard handle != 0 else { return "" }
        return String(decoding: binding.stringUTF8(handle), as: UTF8.self)
    }

    /// Creates a host byte buffer. Returns a +1 handle.
    public static func makeBytes(_ bytes: [UInt8]) -> ObjectHandle {
        bytes.withUnsafeBytes { buffer in
            binding.makeBytes(buffer)
        }
    }

    /// Copies a host byte buffer out. `0` reads as empty.
    public static func bytes(_ handle: ObjectHandle) -> [UInt8] {
        guard handle != 0 else { return [] }
        return binding.bytes(handle)
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
