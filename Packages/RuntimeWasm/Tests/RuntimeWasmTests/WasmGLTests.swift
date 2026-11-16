import Testing
import CGLES2
import CRuntimeGL
import RuntimeABI
import RuntimeCore
import RuntimeWasm
import WAT
import WasmKit

/// What the fake GL was asked to do.
final class FakeGL {

    nonisolated(unsafe) static var shared = FakeGL()

    var floats: [Float] = []

    var bytes: [UInt8] = []

    var calls: [String] = []

    /// Shader sources, attribute and uniform names.
    var strings: [String] = []

    var integers: [Int] = []

    /// Attribute "pointers": offsets into the bound buffer.
    var offsets: [Int] = []

    static let version = Array("OpenGL ES 2.0 (fake)".utf8CString)

    /// A GL that records what a guest draws.
    static func api() -> rt_gl_api {
        var api = rt_gl_api()
        api.glClearColor = { red, green, blue, alpha in
            FakeGL.shared.calls.append("glClearColor")
            FakeGL.shared.floats += [red, green, blue, alpha]
        }
        api.glBufferData = { _, size, data, _ in
            FakeGL.shared.calls.append("glBufferData")
            FakeGL.shared.bytes += Array(UnsafeRawBufferPointer(start: data, count: size))
        }
        api.glGenBuffers = { count, names in
            FakeGL.shared.calls.append("glGenBuffers")
            for index in 0..<Int(count) {
                names![index] = GLuint(100 + index)
            }
        }
        api.glCreateShader = { type in
            FakeGL.shared.calls.append("glCreateShader")
            return type == GL_VERTEX_SHADER ? 11 : 12
        }
        api.glGetString = { name in
            FakeGL.shared.calls.append("glGetString")
            guard name == GL_VERSION else { return nil }
            return FakeGL.version.withUnsafeBufferPointer {
                UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: GLubyte.self)
            }
        }
        return api
    }
}

/// The `env.gl` imports under WasmKit. Part of the serialized suite: the
/// fake GL records into one global.
extension WasmShimTests {

    static let glGuest = """
        (module
          (import "env.gl" "glClearColor" (func $clearColor (param f32 f32 f32 f32)))
          (import "env.gl" "glBufferData" (func $bufferData (param i32 i32 i32 i32)))
          (import "env.gl" "glGenBuffers" (func $genBuffers (param i32 i32)))
          (import "env.gl" "glCreateShader" (func $createShader (param i32) (result i32)))
          (import "env.gl" "glGetString" (func $getString (param i32) (result i32)))
          (memory (export "memory") 1)
          (global $next (mut i32) (i32.const 1024))
          (data (i32.const 16) "\\01\\02\\03\\04")
          ;; A bump allocator stands in for the guest's malloc.
          (func (export "rt_alloc") (param $size i32) (result i32)
            (local $block i32)
            (local.set $block (global.get $next))
            (global.set $next (i32.add (global.get $next) (local.get $size)))
            (local.get $block))
          (func (export "rt_free") (param i32))
          (func (export "draw") (result i32)
            (call $clearColor (f32.const 0.25) (f32.const 0.5) (f32.const 0.75) (f32.const 1))
            ;; glBufferData(GL_ARRAY_BUFFER, 4, 16, GL_STATIC_DRAW)
            (call $bufferData (i32.const 0x8892) (i32.const 4) (i32.const 16) (i32.const 0x88E4))
            (call $genBuffers (i32.const 2) (i32.const 64))
            ;; GL_VERTEX_SHADER
            (call $createShader (i32.const 0x8B31)))
          (func (export "string") (param $name i32) (result i32)
            (call $getString (local.get $name)))
          (func (export "overrun")
            (call $bufferData (i32.const 0x8892) (i32.const 100) (i32.const 65500) (i32.const 0x88E4)))
          (@custom "rt.abi" "\\01\\00\\00\\00")
        )
        """

    func glApp(capabilities: Set<Capability>? = nil, gl: WasmGL? = WasmGL(api: FakeGL.api())) throws -> WasmApp {
        FakeGL.shared = FakeGL()
        return try WasmApp(bytes: try wat2wasm(Self.glGuest), runtime: HostRuntime(), capabilities: capabilities, gl: gl)
    }

    @Test func glCallsReachTheHostsGL() throws {
        let app = try glApp()
        let draw = try #require(app.instance.exports[function: "draw"])
        #expect(try draw().first?.i32 == 11, "glCreateShader's result")
        #expect(FakeGL.shared.calls == ["glClearColor", "glBufferData", "glGenBuffers", "glCreateShader"])
        #expect(FakeGL.shared.floats == [0.25, 0.5, 0.75, 1])
        #expect(FakeGL.shared.bytes == [1, 2, 3, 4], "read from guest memory")
        let memory = try #require(app.instance.exports[memory: "memory"])
        #expect(Array(memory.data[64..<72]) == [100, 0, 0, 0, 101, 0, 0, 0], "written to guest memory")
    }

    @Test func glStringsAreCopiedIntoTheGuestOnce() throws {
        let app = try glApp()
        let string = try #require(app.instance.exports[function: "string"])
        let offset = try #require(try string([.i32(UInt32(GL_VERSION))]).first?.i32)
        #expect(offset == 1024, "from the guest's rt_alloc")
        let memory = try #require(app.instance.exports[memory: "memory"])
        let expected = FakeGL.version.map { UInt8(bitPattern: $0) }
        #expect(Array(memory.data[Int(offset)..<Int(offset) + expected.count]) == expected)

        #expect(try string([.i32(UInt32(GL_VERSION))]).first?.i32 == offset)
        #expect(FakeGL.shared.calls == ["glGetString"], "the copy is reused: a guest may keep the pointer")
        #expect(try string([.i32(UInt32(GL_EXTENSIONS))]).first?.i32 == 0, "GL had none")
    }

    @Test func glPointersOutsideMemoryTrap() throws {
        let app = try glApp()
        let overrun = try #require(app.instance.exports[function: "overrun"])
        #expect(throws: (any Error).self) { try overrun() }
        #expect(FakeGL.shared.calls.isEmpty)

        // The app can go on after the trap is reported.
        let draw = try #require(app.instance.exports[function: "draw"])
        #expect(try draw().first?.i32 == 11)
    }

    @Test func glNeedsTheHostsGLAndTheCapability() throws {
        // A host with no GL, and an app that didn't declare graphics: the
        // module's imports are missing either way.
        #expect(throws: (any Error).self) { try glApp(gl: nil) }
        #expect(throws: (any Error).self) { try glApp(capabilities: [.bluetooth]) }
        #expect(try glApp(capabilities: [.graphics]).gl != nil)
    }

    @Test func glLookupNeedsEveryFunction() throws {
        #expect(throws: WasmRuntimeError.self) {
            try WasmGL { name in name == "glFlush" ? nil : UnsafeMutableRawPointer(bitPattern: 0x10) }
        }
        var asked = 0
        _ = try WasmGL { _ in
            asked += 1
            return UnsafeMutableRawPointer(bitPattern: 0x10)
        }
        #expect(asked == 140)
    }
}
