import CRuntimeGL
import WasmKit

/// The `env.gl` import module: OpenGL ES 2.0 for a wasm32 guest (§8.1).
///
/// The host supplies GL as a table of functions, since this package links
/// against none. Each import goes through the shared shim (`CRuntimeGL`),
/// which turns guest offsets into bounds-checked pointers and applies the
/// WebGL rules; a pointer outside the guest's memory traps the guest.
///
/// ```swift
/// let gl = try WasmGL { name in dlsym(handle, name) }
/// let app = try WasmApp(bytes: bytes, runtime: runtime, gl: gl)
/// ```
///
/// The host makes its GL context current before it calls the guest's
/// `SurfaceDelegate.frame`, the only place a guest may call GL.
public final class WasmGL {

    /// The import module's name.
    public static let moduleName = "env.gl"

    /// The host's GL. Allocated, so the shim's context can point at it.
    let api: UnsafeMutablePointer<rt_gl_api>

    var context = rt_gl_context()

    /// `glGetString` results copied into guest memory, by name. A guest may
    /// keep the pointer, so they're never freed.
    var strings: [UInt32: UInt32] = [:]

    /// - Parameter api: Every function of `rt_gl_api`, filled in.
    public init(api: rt_gl_api) {
        self.api = .allocate(capacity: 1)
        self.api.initialize(to: api)
        rt_gl_context_init(&context)
        context.api = UnsafePointer(self.api)
    }

    /// Looks every GL function up by name, as with `dlsym` or
    /// `eglGetProcAddress`.
    ///
    /// - Throws: `WasmRuntimeError` when a function is missing.
    public convenience init(lookup: (String) -> UnsafeMutableRawPointer?) throws {
        var api = rt_gl_api()
        let missing = withoutActuallyEscaping(lookup) { lookup in
            withUnsafePointer(to: lookup) { lookup in
                rt_gl_api_load(&api, { name, user in
                    let lookup = user!.assumingMemoryBound(to: ((String) -> UnsafeMutableRawPointer?).self).pointee
                    return lookup(String(cString: name!))
                }, UnsafeMutableRawPointer(mutating: lookup))
            }
        }
        guard missing == 0 else {
            throw WasmRuntimeError("the host's GL lacks \(missing) OpenGL ES 2.0 functions")
        }
        self.init(api: api)
    }

    deinit {
        api.deinitialize(count: 1)
        api.deallocate()
    }

    /// Forgets what the shim tracked for the old GL context. Call it when a
    /// context is lost, before `SurfaceDelegate.contextRestored`.
    public func contextLost() {
        rt_gl_context_init(&context)
        context.api = UnsafePointer(api)
    }

    /// Defines every `env.gl` import in `imports`.
    public func define(in imports: inout Imports, store: Store) {
        for index in 0..<rt_gl_function_count() {
            guard let function = rt_gl_function_at(index)?.pointee else { continue }
            let name = String(cString: function.name)
            let parameters = String(cString: function.parameters).map { $0 == "f" ? ValueType.f32 : .i32 }
            let hasResult = function.result == CChar(UInt8(ascii: "i"))
            imports.define(
                module: Self.moduleName,
                name: name,
                Function(store: store, parameters: parameters, results: hasResult ? [.i32] : []) { [unowned self] caller, arguments in
                    let result = try self.call(index, name: name, arguments: arguments, caller: caller)
                    return hasResult ? [.i32(result)] : []
                }
            )
        }
        imports.define(
            module: Self.moduleName,
            name: "glGetString",
            Function(store: store, parameters: [.i32], results: [.i32]) { [unowned self] caller, arguments in
                [.i32(try self.string(arguments[0].i32, caller: caller))]
            }
        )
    }

    /// One call through the shim, with the guest's memory pinned for it.
    private func call(_ index: UInt32, name: String, arguments: [Value], caller: borrowing Caller) throws -> UInt32 {
        guard case .memory(let memory)? = caller.instance?.export("memory") else {
            throw WasmRuntimeError("guest has no \"memory\" export")
        }
        // One slot per argument: an i32, or an f32's bits.
        let slots = arguments.map { argument -> UInt64 in
            switch argument {
            case .f32(let bits): return UInt64(bits)
            default: return UInt64(argument.i32)
            }
        }
        // GL doesn't call back into the guest, so its memory can't move
        // while the pointer is held.
        let result = memory.withUnsafeMutableBufferPointer(offset: 0, count: memory.byteCount) { buffer in
            context.base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            context.size = UInt64(buffer.count)
            return rt_gl_call(&context, index, slots)
        }
        context.base = nil
        context.size = 0
        if context.trapped != 0 {
            context.trapped = 0
            throw WasmRuntimeError("\(name): a pointer outside guest memory")
        }
        return UInt32(truncatingIfNeeded: result)
    }

    /// `glGetString`: the host's string, copied once into memory the guest
    /// allocates. 0 when GL has no such string.
    private func string(_ name: UInt32, caller: borrowing Caller) throws -> UInt32 {
        if let offset = strings[name] {
            return offset
        }
        guard let string = rt_gl_get_string(&context, name) else {
            return 0
        }
        var bytes = [UInt8]()
        var index = 0
        while string[index] != 0 {
            bytes.append(string[index])
            index += 1
        }
        bytes.append(0)
        guard let allocate = caller.instance?.exports[function: "rt_alloc"] else {
            throw WasmRuntimeError("guest has no rt_alloc export")
        }
        let offset = try allocate([.i32(UInt32(bytes.count))]).first?.i32 ?? 0
        guard offset != 0 else {
            return 0
        }
        // Read the memory again: the allocation may have grown it.
        try GuestMemory(caller: caller).write(bytes, at: offset)
        strings[name] = offset
        return offset
    }
}
