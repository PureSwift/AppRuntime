import Foundation
import Testing
import CGLES2
import CRuntimeGL
import DynamicGraphics
import DynamicUI
import RuntimeABI
import RuntimeNative
import RuntimeWasm

/// A host's surface for the example GL app: keeps the delegate, to send
/// frames and input as a player would.
final class WasmTestSurface: Surface {

    nonisolated(unsafe) static var last: WasmTestSurface?

    let delegate: any SurfaceDelegate

    init(delegate: any SurfaceDelegate) {
        self.delegate = delegate
    }

    static func make(_ delegate: any SurfaceDelegate) -> WasmTestSurface {
        let surface = WasmTestSurface(delegate: delegate)
        last = surface
        return surface
    }

    func identifier() -> Int32 { 42 }

    func setPointerCaptured(_ captured: Bool) -> Bool { false }
}

extension FakeGL {

    /// A GL that accepts every shader and records what's drawn.
    static func drawingAPI() -> rt_gl_api {
        var api = FakeGL.api()
        api.glShaderSource = { _, count, strings, lengths in
            FakeGL.shared.calls.append("glShaderSource")
            for index in 0..<Int(count) {
                let bytes = UnsafeRawBufferPointer(start: strings![index], count: Int(lengths![index]))
                FakeGL.shared.strings.append(String(decoding: bytes, as: UTF8.self))
            }
        }
        api.glCompileShader = { _ in FakeGL.shared.calls.append("glCompileShader") }
        api.glGetShaderiv = { _, name, value in value![0] = name == GL_COMPILE_STATUS ? 1 : 0 }
        api.glDeleteShader = { _ in }
        api.glCreateProgram = {
            FakeGL.shared.calls.append("glCreateProgram")
            return 21
        }
        api.glAttachShader = { _, _ in }
        api.glBindAttribLocation = { _, index, name in
            FakeGL.shared.strings.append("\(index)=\(String(cString: name!))")
        }
        api.glLinkProgram = { _ in FakeGL.shared.calls.append("glLinkProgram") }
        api.glGetProgramiv = { _, name, value in value![0] = name == GL_LINK_STATUS ? 1 : 0 }
        api.glDeleteProgram = { _ in }
        api.glGetUniformLocation = { _, name in
            FakeGL.shared.strings.append(String(cString: name!))
            return 3
        }
        api.glBindBuffer = { _, buffer in FakeGL.shared.integers.append(Int(buffer)) }
        api.glViewport = { x, y, width, height in
            FakeGL.shared.calls.append("glViewport")
            FakeGL.shared.integers += [Int(x), Int(y), Int(width), Int(height)]
        }
        api.glClear = { _ in FakeGL.shared.calls.append("glClear") }
        api.glUseProgram = { program in FakeGL.shared.integers.append(Int(program)) }
        api.glUniform1f = { location, value in
            FakeGL.shared.calls.append("glUniform1f")
            FakeGL.shared.integers.append(Int(location))
            FakeGL.shared.floats.append(value)
        }
        api.glEnableVertexAttribArray = { _ in }
        api.glVertexAttribPointer = { _, size, _, _, stride, pointer in
            FakeGL.shared.calls.append("glVertexAttribPointer")
            FakeGL.shared.integers += [Int(size), Int(stride)]
            FakeGL.shared.offsets.append(Int(bitPattern: pointer))
        }
        api.glDrawArrays = { mode, first, count in
            FakeGL.shared.calls.append("glDrawArrays")
            FakeGL.shared.integers += [Int(mode), Int(first), Int(count)]
        }
        return api
    }
}

/// The example GL app as App.wasm under WasmKit: an Embedded Swift guest
/// drawing through `gles2.h`, the `env.gl` imports and the shim, with the
/// `Surface` contract driving it. Part of `WasmShimTests`, which is
/// serialized, since both use `NativeRuntime.shared`.
extension WasmShimTests {

    /// Built by `Scripts/build-wasm.sh ExampleGL`; skipped without it.
    static var exampleGLURL: URL {
        exampleUIURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExampleGL/wasm32/App.wasm")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.exampleGLURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExampleGL"))
    func exampleGLInWasmMode() throws {
        let native = NativeRuntime.shared
        native.capabilities = nil
        RendererProxy.register(WasmTestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        SurfaceProxy.register(WasmTestSurface.self, in: native)
        SurfaceDelegateProxy.registerInterface(in: native)
        WasmTestRenderer.last = nil
        WasmTestSurface.last = nil
        FakeGL.shared = FakeGL()

        let gl = WasmGL(api: FakeGL.drawingAPI())
        let bytes = Array(try Data(contentsOf: Self.exampleGLURL))
        let app = try WasmApp(bytes: bytes, runtime: native.runtime, capabilities: [.graphics], gl: gl)
        let contracts = try #require(WasmApp.contracts(of: app.module))
        #expect(contracts.first { $0.name == "org.pureswift.graphics.Surface" }?.capability == .graphics)
        #expect(WasmApp.validate(app.module, runtime: native.runtime, capabilities: []).contains { $0.severity == .error },
                "an app that draws must declare graphics")
        #expect(try app.start() == .ok)

        // The tree places the host's surface; nothing is drawn before a frame.
        let renderer = try #require(WasmTestRenderer.last)
        let surface = try #require(WasmTestSurface.last)
        var screen = try #require(renderer.screen)
        let node = try #require(screen.first { $0.type == "GLSurface" })
        #expect(node.props["surface"] == .int(42))
        #expect(node.modifiers.first?.kind == "frame")
        #expect(screen.button("Pause") != nil)
        #expect(FakeGL.shared.calls.isEmpty)

        // The first frame makes the GL objects, then draws.
        surface.delegate.resize(surface, width: 640, height: 480, scale: 2)
        surface.delegate.frame(surface, timestamp: 1_000_000_000, width: 640, height: 480)
        let recorded = FakeGL.shared
        #expect(recorded.calls == [
            "glCreateShader", "glShaderSource", "glCompileShader",
            "glCreateShader", "glShaderSource", "glCompileShader",
            "glCreateProgram", "glLinkProgram", "glGenBuffers", "glBufferData",
            "glViewport", "glClearColor", "glClear", "glUniform1f",
            "glVertexAttribPointer", "glVertexAttribPointer", "glDrawArrays",
        ])
        #expect(recorded.strings.count == 5)
        #expect(recorded.strings[0].contains("gl_Position"))
        #expect(recorded.strings[1].hasPrefix("precision mediump float;"))
        #expect(recorded.strings[2...] == ["0=a_position", "1=a_color", "u_angle"])
        // Fifteen floats from the guest's memory: the first corner is (0, 0.8), red.
        #expect(recorded.bytes.count == 60)
        let floats = stride(from: 0, to: 60, by: 4).map { offset in
            Float(bitPattern: recorded.bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) })
        }
        #expect(Array(floats[0..<5]) == [0, 0.8, 1, 0.2, 0.2])
        // Buffer 100 bound for the upload and the draw; viewport; program 21;
        // uniform 3; two attributes of 2 and 3 floats, 20 bytes apart; 3 vertices.
        #expect(recorded.integers == [100, 0, 0, 640, 480, 21, 3, 100, 2, 20, 3, 20, Int(GL_TRIANGLES), 0, 3])
        #expect(recorded.offsets == [0, 8], "offsets into the buffer, not pointers")
        #expect(recorded.floats == [0.08, 0.08, 0.1, 1, 0], "the clear color, then angle 0")

        // Half a second later: only a draw, half a radian on.
        FakeGL.shared = FakeGL()
        surface.delegate.frame(surface, timestamp: 1_500_000_000, width: 640, height: 480)
        #expect(FakeGL.shared.calls == ["glViewport", "glClearColor", "glClear", "glUniform1f",
                                        "glVertexAttribPointer", "glVertexAttribPointer", "glDrawArrays"])
        #expect(FakeGL.shared.floats.last == 0.5)

        // A touch on the surface reverses the spin, and the UI says so.
        #expect(screen.first { $0.props["text"] == "Counter-clockwise" } != nil)
        surface.delegate.pointer(surface, id: 1, kind: 0, phase: 0, x: 10, y: 10, buttons: 1, timestamp: 1_600_000_000)
        screen = try #require(renderer.screen)
        #expect(screen.first { $0.props["text"] == "Clockwise" } != nil)
        surface.delegate.frame(surface, timestamp: 1_750_000_000, width: 640, height: 480)
        #expect(FakeGL.shared.floats.last == 0.25)

        // Space pauses; so does the button.
        surface.delegate.key(surface, code: KeyCode.space.rawValue, pressed: true, modifiers: 0, isRepeat: false, timestamp: 1_800_000_000)
        screen = try #require(renderer.screen)
        let resume = try #require(screen.button("Resume"))
        surface.delegate.frame(surface, timestamp: 2_750_000_000, width: 640, height: 480)
        #expect(FakeGL.shared.floats.last == 0.25, "paused")
        renderer.send(resume, .tap)
        #expect(renderer.screen?.button("Pause") != nil)

        // A lost context: the guest makes its objects again in the new one.
        FakeGL.shared = FakeGL()
        surface.delegate.contextLost(surface)
        gl.contextLost()
        surface.delegate.contextRestored(surface)
        surface.delegate.frame(surface, timestamp: 3_000_000_000, width: 640, height: 480)
        #expect(FakeGL.shared.calls.prefix(3) == ["glCreateShader", "glShaderSource", "glCompileShader"])
        #expect(FakeGL.shared.calls.last == "glDrawArrays")
    }
}
