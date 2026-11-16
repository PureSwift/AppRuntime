import Testing
import CFakeGL
import CRuntime
import DynamicGraphics
import DynamicUI
import RuntimeABI
import RuntimeNative

/// A host's surface for the example GL app: keeps the delegate, to send
/// frames and input as a player would.
final class TestSurface: Surface {

    nonisolated(unsafe) static var last: TestSurface?

    let delegate: any SurfaceDelegate

    init(delegate: any SurfaceDelegate) {
        self.delegate = delegate
    }

    static func make(_ delegate: any SurfaceDelegate) -> TestSurface {
        let surface = TestSurface(delegate: delegate)
        last = surface
        return surface
    }

    func identifier() -> Int32 { 42 }

    func setPointerCaptured(_ captured: Bool) -> Bool { false }
}

/// What the fake GL was asked since the last reset, a call a line.
func drawn() -> [String] {
    String(cString: fake_gl_log()).split(separator: "\n").map(String.init)
}

/// `ExampleGL`'s library drawing into a GL that writes its calls down: the
/// guest's `gles2.h` calls as a native slice's `gl*` symbols, or through
/// wasm2c and the GL shim (see `Package.swift`), which must come out the
/// same. Part of `LinkedSliceTests`, which is serialized, since both use
/// `NativeRuntime.shared`.
extension LinkedSliceTests {

    static var linksExampleGL: Bool {
        #if LINKED_EXAMPLEGL
        true
        #else
        false
        #endif
    }

    @Test(.enabled(if: linksExampleGL, "Link ExampleGL's library first; see Packages/LinkedSlice/Package.swift"))
    func exampleGL() throws {
        #if LINKED_EXAMPLEGL
        native.capabilities = nil
        RendererProxy.register(TestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        SurfaceProxy.register(TestSurface.self, in: native)
        SurfaceDelegateProxy.registerInterface(in: native)
        TestRenderer.last = nil
        TestSurface.last = nil
        fake_gl_reset()

        #expect(native.start(rt_main, dispatch: rt_dispatch, finalize: rt_finalize) == .ok)
        let renderer = try #require(TestRenderer.last)
        let surface = try #require(TestSurface.last)
        var screen = try #require(renderer.screen)
        #expect(screen.first { $0.type == "GLSurface" }?.props["surface"] == .int(42))
        #expect(drawn().isEmpty, "nothing is drawn before a frame")

        // The first frame makes the GL objects, then draws.
        surface.delegate.resize(surface, width: 640, height: 480, scale: 2)
        surface.delegate.frame(surface, timestamp: 1_000_000_000, width: 640, height: 480)
        let first = drawn()
        // GL names count up from wherever earlier tests left them.
        let compile = try #require(first.first { $0.hasPrefix("glCompileShader(") })
        let vertex = try #require(UInt32(compile.dropFirst("glCompileShader(".count).dropLast()))
        let fragment = vertex + 1, program = vertex + 2, buffer = vertex + 3
        #expect(first == [
            "glCreateShader(0x8B31)",
            "glShaderSource(\(vertex), 1, *, *)",
            "glCompileShader(\(vertex))",
            "glGetShaderiv(\(vertex), 0x8B81, *)",
            "glCreateShader(0x8B30)",
            "glShaderSource(\(fragment), 1, *, *)",
            "glCompileShader(\(fragment))",
            "glGetShaderiv(\(fragment), 0x8B81, *)",
            "glCreateProgram()",
            "glAttachShader(\(program), \(vertex))",
            "glAttachShader(\(program), \(fragment))",
            "glBindAttribLocation(\(program), 0, \"a_position\")",
            "glBindAttribLocation(\(program), 1, \"a_color\")",
            "glLinkProgram(\(program))",
            "glDeleteShader(\(vertex))",
            "glDeleteShader(\(fragment))",
            "glGetProgramiv(\(program), 0x8B82, *)",
            "glGetUniformLocation(\(program), \"u_angle\")",
            "glGenBuffers(1, *)",
            "glBindBuffer(0x8892, \(buffer))",
            "glBufferData(0x8892, 60, *, 0x88E4)",
            "glViewport(0, 0, 640, 480)",
            "glClearColor(0.08, 0.08, 0.1, 1)",
            "glClear(0x4000)",
            "glUseProgram(\(program))",
            "glUniform1f(3, 0)",
            "glBindBuffer(0x8892, \(buffer))",
            "glEnableVertexAttribArray(0)",
            "glVertexAttribPointer(0, 2, 0x1406, 0, 20, 0)",
            "glEnableVertexAttribArray(1)",
            "glVertexAttribPointer(1, 3, 0x1406, 0, 20, 8)",
            "glDrawArrays(0x0004, 0, 3)",
        ])

        // Half a second later: only a draw, half a radian on.
        fake_gl_reset()
        surface.delegate.frame(surface, timestamp: 1_500_000_000, width: 640, height: 480)
        #expect(drawn().count == 11)
        #expect(drawn().contains("glUniform1f(3, 0.5)"))

        // A touch on the surface reverses the spin, and the UI says so.
        surface.delegate.pointer(surface, id: 1, kind: 0, phase: 0, x: 10, y: 10, buttons: 1, timestamp: 1_600_000_000)
        screen = try #require(renderer.screen)
        #expect(screen.first { $0.props["text"] == "Clockwise" } != nil)
        fake_gl_reset()
        surface.delegate.frame(surface, timestamp: 1_750_000_000, width: 640, height: 480)
        #expect(drawn().contains("glUniform1f(3, 0.25)"))

        // Space pauses.
        surface.delegate.key(surface, code: KeyCode.space.rawValue, pressed: true, modifiers: 0, isRepeat: false, timestamp: 1_800_000_000)
        #expect(renderer.screen?.button("Resume") != nil)
        fake_gl_reset()
        surface.delegate.frame(surface, timestamp: 2_750_000_000, width: 640, height: 480)
        #expect(drawn().contains("glUniform1f(3, 0.25)"), "paused")

        // A lost context: the guest makes its objects again in the new one.
        // The wasm2c shim learns of it from the generation; a native slice
        // has no shim to tell.
        fake_gl_reset()
        surface.delegate.contextLost(surface)
        fake_gl_new_context()
        surface.delegate.contextRestored(surface)
        surface.delegate.frame(surface, timestamp: 3_000_000_000, width: 640, height: 480)
        #expect(drawn().first == "glCreateShader(0x8B31)")
        #expect(drawn().last == "glDrawArrays(0x0004, 0, 3)")
        #expect(drawn().count == first.count)
        #endif
    }
}
