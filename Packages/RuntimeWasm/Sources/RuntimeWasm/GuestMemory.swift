import RuntimeABI
import WasmKit

/// Bounds-checked copies in and out of a guest's linear memory.
///
/// The host never keeps a pointer into linear memory past one access,
/// because `memory.grow` can move it (§6.3).
struct GuestMemory {

    let memory: Memory

    init(_ memory: Memory) {
        self.memory = memory
    }

    init(caller: borrowing Caller) throws {
        guard case .memory(let memory)? = caller.instance?.export("memory") else {
            throw WasmRuntimeError("guest has no \"memory\" export")
        }
        self.memory = memory
    }

    private func check(_ offset: UInt32, _ count: Int) throws {
        guard count >= 0, UInt64(offset) + UInt64(count) <= UInt64(memory.byteCount) else {
            throw WasmRuntimeError("guest memory access out of bounds (offset \(offset), \(count) bytes)")
        }
    }

    func read(_ offset: UInt32, count: UInt32) throws -> [UInt8] {
        let count = Int(count)
        guard count > 0 else { return [] }
        try check(offset, count)
        return memory.withUnsafeBufferPointer(offset: UInt(offset), count: count) { Array($0) }
    }

    func write(_ bytes: [UInt8], at offset: UInt32) throws {
        guard !bytes.isEmpty else { return }
        try check(offset, bytes.count)
        memory.withUnsafeMutableBufferPointer(offset: UInt(offset), count: bytes.count) { buffer in
            buffer.copyBytes(from: bytes)
        }
    }

    /// Copies at most `capacity` bytes to `offset`; returns the full length,
    /// as `rt_string_utf8` / `rt_bytes_read` / `rt_error_message` do.
    func copyOut(_ bytes: [UInt8], to offset: UInt32, capacity: UInt32) throws -> UInt32 {
        let count = min(bytes.count, Int(capacity))
        if count > 0 {
            try write(Array(bytes[0..<count]), at: offset)
        }
        return UInt32(truncatingIfNeeded: bytes.count)
    }

    func readUInt32s(_ offset: UInt32, count: UInt32) throws -> [UInt32] {
        let bytes = try read(offset, count: count * 4)
        return stride(from: 0, to: bytes.count, by: 4).map { index in
            UInt32(bytes[index])
                | UInt32(bytes[index + 1]) << 8
                | UInt32(bytes[index + 2]) << 16
                | UInt32(bytes[index + 3]) << 24
        }
    }

    func readSlots(_ offset: UInt32, count: UInt32) throws -> [Slot] {
        let bytes = try read(offset, count: count * 8)
        return stride(from: 0, to: bytes.count, by: 8).map { index in
            var value: Slot = 0
            for byte in 0..<8 {
                value |= Slot(bytes[index + byte]) << Slot(byte * 8)
            }
            return value
        }
    }

    func writeSlots(_ slots: [Slot], at offset: UInt32) throws {
        var bytes = [UInt8]()
        bytes.reserveCapacity(slots.count * 8)
        for slot in slots {
            for byte in 0..<8 {
                bytes.append(UInt8(truncatingIfNeeded: slot >> Slot(byte * 8)))
            }
        }
        try write(bytes, at: offset)
    }
}

/// An error raised by the wasm shim. Thrown from a host function, it traps
/// the guest.
public struct WasmRuntimeError: Error, CustomStringConvertible {

    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}
