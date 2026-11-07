import CRuntime
import RuntimeABI
import RuntimeCore

// The rt.h imports as C symbols, for native slices and host code.
// Every function forwards to `NativeRuntime.shared`.

private var runtime: HostRuntime {
    NativeRuntime.shared.runtime
}

private var guest: NativeGuest {
    NativeRuntime.shared.guest
}

private func bytes(_ pointer: UnsafeRawPointer?, _ count: Int) -> UnsafeRawBufferPointer {
    guard let pointer, count > 0 else { return UnsafeRawBufferPointer(start: nil, count: 0) }
    return UnsafeRawBufferPointer(start: pointer, count: count)
}

/// Copies at most `capacity` bytes and returns the full length.
private func copy(_ source: [UInt8], to destination: UnsafeMutableRawPointer?, capacity: Int) -> Int {
    if let destination, capacity > 0 {
        source.withUnsafeBytes { source in
            destination.copyMemory(from: source.baseAddress!, byteCount: min(source.count, capacity))
        }
    }
    return source.count
}

@c(rt_class)
public func _rt_class(_ name: UnsafePointer<CChar>?, _ length: Int) -> rt_class_id {
    runtime.lookupClass(bytes(name, length), guest: guest)
}

@c(rt_method)
public func _rt_method(
    _ cls: rt_class_id,
    _ name: UnsafePointer<CChar>?,
    _ nameLength: Int,
    _ signature: UnsafePointer<CChar>?,
    _ signatureLength: Int,
    _ flags: UInt32
) -> rt_method_id {
    runtime.lookupMethod(cls, key: bytes(name, nameLength), signature: bytes(signature, signatureLength), flags: flags)
}

@c(rt_call)
public func _rt_call(
    _ target: rt_obj,
    _ method: rt_method_id,
    _ arguments: UnsafePointer<rt_slot>?,
    _ argumentCount: UInt32,
    _ results: UnsafeMutablePointer<rt_slot>?,
    _ resultCount: UInt32
) -> rt_status {
    let status = runtime.call(
        target: target,
        method: method,
        arguments: UnsafeBufferPointer(start: arguments, count: arguments == nil ? 0 : Int(argumentCount)),
        results: UnsafeMutableBufferPointer(start: results, count: results == nil ? 0 : Int(resultCount))
    )
    return rt_status(rawValue: status.rawValue)
}

@c(rt_retain)
public func _rt_retain(_ object: rt_obj) {
    runtime.retain(object)
}

@c(rt_release)
public func _rt_release(_ object: rt_obj) {
    runtime.release(object)
}

@c(rt_same)
public func _rt_same(_ a: rt_obj, _ b: rt_obj) -> Int32 {
    runtime.same(a, b) ? 1 : 0
}

@c(rt_is_instance)
public func _rt_is_instance(_ object: rt_obj, _ cls: rt_class_id) -> Int32 {
    runtime.isInstance(object, of: cls) ? 1 : 0
}

@c(rt_string_new)
public func _rt_string_new(_ utf8: UnsafePointer<CChar>?, _ length: Int) -> rt_obj {
    runtime.makeString(utf8: bytes(utf8, length))
}

@c(rt_string_utf8)
public func _rt_string_utf8(_ string: rt_obj, _ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int {
    copy(runtime.stringUTF8(string) ?? [], to: UnsafeMutableRawPointer(buffer), capacity: capacity)
}

@c(rt_bytes_new)
public func _rt_bytes_new(_ pointer: UnsafeRawPointer?, _ length: Int) -> rt_obj {
    runtime.makeBytes(bytes(pointer, length))
}

@c(rt_bytes_read)
public func _rt_bytes_read(_ object: rt_obj, _ buffer: UnsafeMutableRawPointer?, _ capacity: Int) -> Int {
    copy(runtime.bytes(object) ?? [], to: buffer, capacity: capacity)
}

@c(rt_implement)
public func _rt_implement(
    _ interfaces: UnsafePointer<rt_class_id>?,
    _ interfaceCount: UInt32,
    _ methods: UnsafePointer<rt_method_decl>?,
    _ methodCount: UInt32,
    _ context: UInt32
) -> rt_obj {
    let interfaces = Array(UnsafeBufferPointer(start: interfaces, count: interfaces == nil ? 0 : Int(interfaceCount)))
    let declarations = UnsafeBufferPointer(start: methods, count: methods == nil ? 0 : Int(methodCount)).map { declaration in
        (
            key: Array(bytes(declaration.name, declaration.name_len)),
            signature: Array(bytes(declaration.sig, declaration.sig_len))
        )
    }
    return runtime.implement(interfaces: interfaces, methods: declarations, context: context, guest: guest)
}

@c(rt_error_message)
public func _rt_error_message(_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int {
    copy(runtime.errorMessage(capacity: capacity), to: UnsafeMutableRawPointer(buffer), capacity: capacity)
}
