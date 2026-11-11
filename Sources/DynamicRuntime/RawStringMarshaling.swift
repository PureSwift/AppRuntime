import RuntimeABI

// Marshaling for `RawRepresentable` types with `String` raw values, such as
// `BluetoothUUID`. A contract can declare them directly; on the wire they are
// ordinary host strings.
//
// A macro only sees syntax, so it can't tell these types from contract
// protocols. Generated code calls the functions below by name, each contract
// emits overloads of them for its own protocol, and the compiler picks.
//
// Decoding fails with `RuntimeError.thrown` when the string isn't a valid raw
// value, so a contract method returning one of these types must be declared
// `throws`.

/// Creates the host string for `value`. Returns a +1 handle.
public func _rtEncode<T: RawRepresentable>(_ value: T) -> ObjectHandle where T.RawValue == String {
    Runtime.makeString(value.rawValue)
}

/// Decodes a +1 handle, taking ownership of it even when decoding fails.
public func _rtDecodeRetained<T: RawRepresentable>(
    _ handle: ObjectHandle
) throws(RuntimeError) -> T where T.RawValue == String {
    guard handle != 0 else { throw RuntimeError.null }
    defer { Runtime.release(handle) }
    return try rawValue(Runtime.string(handle))
}

/// Decodes a borrowed handle.
public func _rtDecodeBorrowed<T: RawRepresentable>(
    _ handle: ObjectHandle
) throws(RuntimeError) -> T where T.RawValue == String {
    guard handle != 0 else { throw RuntimeError.null }
    return try rawValue(Runtime.string(handle))
}

/// Only contract objects can be the result of a non-throwing method.
@available(*, unavailable, message: "a contract method returning a RawRepresentable string type must be declared 'throws', because the host can return an invalid string")
public func _rtResult<T: RawRepresentable>(_ handle: ObjectHandle) -> T where T.RawValue == String {
    fatalError("unavailable")
}

private func rawValue<T: RawRepresentable>(_ string: String) throws(RuntimeError) -> T where T.RawValue == String {
    guard let value = T(rawValue: string) else {
        throw RuntimeError.thrown("Invalid string value: \(string)")
    }
    return value
}
