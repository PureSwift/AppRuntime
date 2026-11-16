import DynamicRuntime
import DynamicGraphics
// Guest builds call the frontend `SwiftUI`; host builds of this package
// can't, since Apple's SDK has one. A guest package just says `import SwiftUI`.
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The example GL app (§8): a triangle drawn with OpenGL ES 2.0 in a
/// surface, with SwiftUI controls around it. A tap or click on the surface
/// reverses the spin, and Space pauses it.

// MARK: - Drawing

/// GLSL ES 1.00, with explicit precision, as WebGL 1 requires.
let vertexShader: StaticString = """
    attribute vec2 a_position;
    attribute vec3 a_color;
    uniform float u_angle;
    varying vec3 v_color;
    void main() {
        float c = cos(u_angle);
        float s = sin(u_angle);
        gl_Position = vec4(a_position.x * c - a_position.y * s, a_position.x * s + a_position.y * c, 0.0, 1.0);
        v_color = a_color;
    }
    """

let fragmentShader: StaticString = """
    precision mediump float;
    varying vec3 v_color;
    void main() {
        gl_FragColor = vec4(v_color, 1.0);
    }
    """

/// A string literal as GL takes it. It's NUL-terminated.
func glString(_ string: StaticString) -> UnsafePointer<GLchar> {
    UnsafeRawPointer(string.utf8Start).assumingMemoryBound(to: GLchar.self)
}

/// The triangle's GL objects. They live in the surface's GL context, so
/// they're made in the first frame and again after a lost context.
final class Triangle {

    var program: GLuint = 0

    var buffer: GLuint = 0

    var angleLocation: GLint = -1

    /// x, y, red, green, blue for each corner.
    static let vertices: [GLfloat] = [
        0.0, 0.8, 1, 0.2, 0.2,
        -0.7, -0.4, 0.2, 1, 0.2,
        0.7, -0.4, 0.2, 0.4, 1,
    ]

    static let stride = GLsizei(5 * MemoryLayout<GLfloat>.size)

    var isLoaded: Bool { program != 0 }

    func compile(_ type: GLenum, _ source: StaticString) -> GLuint {
        let shader = glCreateShader(type)
        var text: UnsafePointer<GLchar>? = glString(source)
        var length = GLint(source.utf8CodeUnitCount)
        glShaderSource(shader, 1, &text, &length)
        glCompileShader(shader)
        var compiled: GLint = 0
        glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled)
        if compiled == 0 {
            glDeleteShader(shader)
            return 0
        }
        return shader
    }

    /// Makes the program and the vertex buffer. `false` when GL refuses.
    func load() -> Bool {
        let vertex = compile(GL_VERTEX_SHADER, vertexShader)
        let fragment = compile(GL_FRAGMENT_SHADER, fragmentShader)
        guard vertex != 0, fragment != 0 else { return false }
        let program = glCreateProgram()
        glAttachShader(program, vertex)
        glAttachShader(program, fragment)
        glBindAttribLocation(program, 0, glString("a_position"))
        glBindAttribLocation(program, 1, glString("a_color"))
        glLinkProgram(program)
        // The program keeps what it needs of them.
        glDeleteShader(vertex)
        glDeleteShader(fragment)
        var linked: GLint = 0
        glGetProgramiv(program, GL_LINK_STATUS, &linked)
        guard linked != 0 else {
            glDeleteProgram(program)
            return false
        }
        angleLocation = glGetUniformLocation(program, glString("u_angle"))
        self.program = program

        glGenBuffers(1, &buffer)
        glBindBuffer(GL_ARRAY_BUFFER, buffer)
        Self.vertices.withUnsafeBufferPointer { vertices in
            glBufferData(GL_ARRAY_BUFFER, vertices.count * MemoryLayout<GLfloat>.size, vertices.baseAddress, GL_STATIC_DRAW)
        }
        return true
    }

    func draw(width: Int32, height: Int32, angle: Float) {
        glViewport(0, 0, width, height)
        glClearColor(0.08, 0.08, 0.1, 1)
        glClear(GL_COLOR_BUFFER_BIT)
        glUseProgram(program)
        glUniform1f(angleLocation, angle)
        // Vertex data comes from the buffer: the "pointers" are offsets.
        glBindBuffer(GL_ARRAY_BUFFER, buffer)
        glEnableVertexAttribArray(0)
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, Self.stride, nil)
        glEnableVertexAttribArray(1)
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, Self.stride, UnsafeRawPointer(bitPattern: 2 * MemoryLayout<GLfloat>.size))
        glDrawArrays(GL_TRIANGLES, 0, 3)
    }

    /// The context is gone, and the objects with it.
    func forget() {
        program = 0
        buffer = 0
        angleLocation = -1
    }
}

// MARK: - Model

@Observable
final class Scene3D {

    var isPaused: Bool = false

    var isReversed: Bool = false

    /// Whether GL accepted the shaders.
    var failed: Bool = false

    @ObservationIgnored let triangle = Triangle()

    @ObservationIgnored let events = SurfaceEvents()

    @ObservationIgnored var surface: (any Surface)?

    /// Radians, advanced by the frames' timestamps while not paused.
    @ObservationIgnored var angle: Float = 0

    @ObservationIgnored var lastTimestamp: Int64 = 0

    /// The closures hold the scene, which lives as long as the app does:
    /// Embedded Swift has no weak or unowned references.
    func start() {
        events.onFrame = { frame in
            self.draw(frame)
        }
        events.onContextLost = {
            self.triangle.forget()
        }
        events.onPointer = { pointer in
            if pointer.phase == .down {
                self.isReversed.toggle()
            }
        }
        events.onKey = { key in
            if key.code == .space, key.pressed, !key.isRepeat {
                self.isPaused.toggle()
            }
        }
        surface = SurfaceProxy.make(events)
    }

    func draw(_ frame: SurfaceFrame) {
        if !triangle.isLoaded {
            guard !failed else { return }
            guard triangle.load() else {
                failed = true
                return
            }
        }
        if lastTimestamp != 0, !isPaused {
            let seconds = Float(frame.timestamp - lastTimestamp) / 1_000_000_000
            angle += isReversed ? -seconds : seconds
        }
        lastTimestamp = frame.timestamp
        triangle.draw(width: frame.width, height: frame.height, angle: angle)
    }
}

// MARK: - Views

struct ContentView: View {

    let scene: Scene3D

    var body: some View {
        VStack(spacing: 12) {
            Text("OpenGL ES 2.0")
                .font(.headline)
            if let surface = scene.surface {
                GLSurface(surface.identifier())
                    .frame(height: 280)
            }
            if scene.failed {
                Text("The shaders didn't compile.")
            }
            Text(scene.isReversed ? "Clockwise" : "Counter-clockwise")
            Button(scene.isPaused ? "Resume" : "Pause") {
                scene.isPaused.toggle()
            }
        }
        .padding()
    }
}

struct ExampleGLApp: App {

    let scene = Scene3D()

    init() {
        scene.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(scene: scene)
        }
    }
}

/// The app's entry point. The host calls it once after loading the slice.
@_expose(wasm, "rt_main")
@c(rt_main)
public func exampleGLMain() -> rt_status {
    Runtime.main { ExampleGLApp.run() }
}
