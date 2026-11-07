import RuntimeABI
import RuntimeCore
import WasmKit

/// The `rt` import module: rt.h for wasm32 guests.
///
/// Each import converts guest offsets into bounds-checked copies and calls
/// the runtime core. Pointers and `size_t` are i32 on wasm32.
public enum WasmImports {

    /// Defines every `rt.*` import in `imports`.
    public static func define(
        in imports: inout Imports,
        store: Store,
        runtime: HostRuntime,
        guest: WasmGuest
    ) {
        func function(
            _ name: String,
            _ parameters: [ValueType],
            _ results: [ValueType],
            _ body: @escaping (borrowing Caller, [Value]) throws -> [Value]
        ) {
            imports.define(module: "rt", name: name, Function(store: store, parameters: parameters, results: results, body: body))
        }

        function("class", [.i32, .i32], [.i32]) { caller, arguments in
            let name = try GuestMemory(caller: caller).read(arguments[0].i32, count: arguments[1].i32)
            return [.i32(runtime.lookupClass(name, guest: guest))]
        }

        function("method", [.i32, .i32, .i32, .i32, .i32, .i32], [.i32]) { caller, arguments in
            let memory = try GuestMemory(caller: caller)
            let key = try memory.read(arguments[1].i32, count: arguments[2].i32)
            let signature = try memory.read(arguments[3].i32, count: arguments[4].i32)
            return [.i32(runtime.lookupMethod(arguments[0].i32, key: key, signature: signature, flags: arguments[5].i32))]
        }

        function("call", [.i32, .i32, .i32, .i32, .i32, .i32], [.i32]) { caller, arguments in
            let slots = try GuestMemory(caller: caller).readSlots(arguments[2].i32, count: arguments[3].i32)
            let resultsOffset = arguments[4].i32
            var results = [Slot](repeating: 0, count: Int(arguments[5].i32))
            let status = slots.withUnsafeBufferPointer { slots in
                results.withUnsafeMutableBufferPointer { results in
                    runtime.call(target: arguments[0].i32, method: arguments[1].i32, arguments: slots, results: results)
                }
            }
            // The call may have re-entered the guest and grown its memory.
            if status == .ok {
                try GuestMemory(caller: caller).writeSlots(results, at: resultsOffset)
            }
            return [.i32(status.rawValue)]
        }

        function("retain", [.i32], []) { _, arguments in
            runtime.retain(arguments[0].i32)
            return []
        }

        function("release", [.i32], []) { _, arguments in
            runtime.release(arguments[0].i32)
            return []
        }

        function("same", [.i32, .i32], [.i32]) { _, arguments in
            [.i32(runtime.same(arguments[0].i32, arguments[1].i32) ? 1 : 0)]
        }

        function("is_instance", [.i32, .i32], [.i32]) { _, arguments in
            [.i32(runtime.isInstance(arguments[0].i32, of: arguments[1].i32) ? 1 : 0)]
        }

        function("string_new", [.i32, .i32], [.i32]) { caller, arguments in
            let utf8 = try GuestMemory(caller: caller).read(arguments[0].i32, count: arguments[1].i32)
            return [.i32(runtime.makeString(utf8: utf8))]
        }

        function("string_utf8", [.i32, .i32, .i32], [.i32]) { caller, arguments in
            let utf8 = runtime.stringUTF8(arguments[0].i32) ?? []
            return [.i32(try GuestMemory(caller: caller).copyOut(utf8, to: arguments[1].i32, capacity: arguments[2].i32))]
        }

        function("bytes_new", [.i32, .i32], [.i32]) { caller, arguments in
            let bytes = try GuestMemory(caller: caller).read(arguments[0].i32, count: arguments[1].i32)
            return [.i32(runtime.makeBytes(bytes))]
        }

        function("bytes_read", [.i32, .i32, .i32], [.i32]) { caller, arguments in
            let bytes = runtime.bytes(arguments[0].i32) ?? []
            return [.i32(try GuestMemory(caller: caller).copyOut(bytes, to: arguments[1].i32, capacity: arguments[2].i32))]
        }

        function("implement", [.i32, .i32, .i32, .i32, .i32], [.i32]) { caller, arguments in
            let memory = try GuestMemory(caller: caller)
            let interfaces = try memory.readUInt32s(arguments[0].i32, count: arguments[1].i32)
            // rt_method_decl on wasm32: { name, name_len, sig, sig_len }, 16 bytes.
            let fields = try memory.readUInt32s(arguments[2].i32, count: arguments[3].i32 * 4)
            var declarations = [(key: [UInt8], signature: [UInt8])]()
            for index in stride(from: 0, to: fields.count, by: 4) {
                declarations.append((
                    key: try memory.read(fields[index], count: fields[index + 1]),
                    signature: try memory.read(fields[index + 2], count: fields[index + 3])
                ))
            }
            return [.i32(runtime.implement(interfaces: interfaces, methods: declarations, context: arguments[4].i32, guest: guest))]
        }

        function("error_message", [.i32, .i32], [.i32]) { caller, arguments in
            let capacity = arguments[1].i32
            let message = runtime.errorMessage(capacity: Int(capacity))
            return [.i32(try GuestMemory(caller: caller).copyOut(message, to: arguments[0].i32, capacity: capacity))]
        }
    }
}
