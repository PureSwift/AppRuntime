import Testing
import CGLES2
import CRuntimeGL

/// What the fake GL was asked to do.
final class GLRecorder {

    nonisolated(unsafe) static var shared = GLRecorder()

    var calls: [String] = []

    /// Bytes read through pointers GL was given.
    var bytes: [[UInt8]] = []

    var pointers: [UnsafeRawPointer?] = []

    var strings: [String] = []

    var floats: [Float] = []

    var integers: [Int] = []

    /// What `glGetError` reports.
    var error: GLenum = 0
}

/// A guest's linear memory and a shim context over a recording GL.
final class GLFixture {

    let memory: UnsafeMutablePointer<UInt8>

    let size: Int

    var api = rt_gl_api()

    var context = rt_gl_context()

    init(size: Int = 256) {
        self.size = size
        memory = .allocate(capacity: size)
        memory.initialize(repeating: 0, count: size)
        GLRecorder.shared = GLRecorder()
        Self.install(&api)
        rt_gl_context_init(&context)
        context.base = memory
        context.size = UInt64(size)
    }

    deinit {
        memory.deallocate()
    }

    /// Runs `body` with the context pointing at the fake GL.
    func call<T>(_ body: (UnsafeMutablePointer<rt_gl_context>) -> T) -> T {
        withUnsafePointer(to: &api) { api in
            context.api = api
            return body(&context)
        }
    }

    func write(_ bytes: [UInt8], at offset: Int) {
        for (index, byte) in bytes.enumerated() {
            memory[offset + index] = byte
        }
    }

    func write32(_ value: UInt32, at offset: Int) {
        write([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)], at: offset)
    }

    func read(_ offset: Int, _ count: Int) -> [UInt8] {
        (0..<count).map { memory[offset + $0] }
    }

    func read32(_ offset: Int) -> UInt32 {
        read(offset, 4).enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
    }

    static func install(_ api: inout rt_gl_api) {
        api.glBufferData = { _, size, data, _ in
            let recorder = GLRecorder.shared
            recorder.calls.append("glBufferData")
            recorder.pointers.append(data)
            if let data {
                recorder.bytes.append(Array(UnsafeRawBufferPointer(start: data, count: size)))
            }
        }
        api.glGenBuffers = { count, names in
            GLRecorder.shared.calls.append("glGenBuffers")
            for index in 0..<Int(count) {
                names?[index] = GLuint(100 + index)
            }
        }
        api.glBindBuffer = { target, buffer in
            GLRecorder.shared.calls.append("glBindBuffer")
            GLRecorder.shared.integers += [Int(target), Int(buffer)]
        }
        api.glDeleteBuffers = { _, _ in
            GLRecorder.shared.calls.append("glDeleteBuffers")
        }
        api.glEnableVertexAttribArray = { _ in GLRecorder.shared.calls.append("glEnableVertexAttribArray") }
        api.glDisableVertexAttribArray = { _ in GLRecorder.shared.calls.append("glDisableVertexAttribArray") }
        api.glVertexAttribPointer = { _, _, _, _, _, pointer in
            GLRecorder.shared.calls.append("glVertexAttribPointer")
            GLRecorder.shared.pointers.append(pointer)
        }
        api.glDrawArrays = { _, _, _ in GLRecorder.shared.calls.append("glDrawArrays") }
        api.glDrawElements = { _, _, _, indices in
            GLRecorder.shared.calls.append("glDrawElements")
            GLRecorder.shared.pointers.append(indices)
        }
        api.glGetError = {
            GLRecorder.shared.calls.append("glGetError")
            return GLRecorder.shared.error
        }
        api.glGetUniformLocation = { _, name in
            GLRecorder.shared.calls.append("glGetUniformLocation")
            GLRecorder.shared.strings.append(String(cString: name!))
            return -1
        }
        api.glShaderSource = { _, count, strings, lengths in
            GLRecorder.shared.calls.append("glShaderSource")
            for index in 0..<Int(count) {
                let start = UnsafeRawPointer(strings![index]!)
                let bytes = UnsafeRawBufferPointer(start: start, count: Int(lengths![index]))
                GLRecorder.shared.strings.append(String(decoding: bytes, as: UTF8.self))
            }
        }
        api.glPixelStorei = { _, _ in GLRecorder.shared.calls.append("glPixelStorei") }
        api.glTexImage2D = { _, _, _, _, _, _, _, _, pixels in
            GLRecorder.shared.calls.append("glTexImage2D")
            GLRecorder.shared.pointers.append(pixels)
        }
        api.glReadPixels = { _, _, width, height, _, _, pixels in
            GLRecorder.shared.calls.append("glReadPixels")
            // RGBA, alignment 4: no padding.
            let buffer = pixels!.assumingMemoryBound(to: UInt8.self)
            for index in 0..<Int(width * height * 4) {
                buffer[index] = 0xAB
            }
        }
        api.glGetIntegerv = { name, values in
            GLRecorder.shared.calls.append("glGetIntegerv")
            switch name {
            case GL_VIEWPORT:
                for index in 0..<4 { values![index] = GLint(index + 1) }
            default:
                values![0] = 42
            }
        }
        api.glGetUniformfv = { _, _, values in
            GLRecorder.shared.calls.append("glGetUniformfv")
            // A vec2.
            values![0] = 1.5
            values![1] = -2
        }
        api.glClearColor = { red, green, blue, alpha in
            GLRecorder.shared.calls.append("glClearColor")
            GLRecorder.shared.floats += [red, green, blue, alpha]
        }
        api.glCreateShader = { type in
            GLRecorder.shared.calls.append("glCreateShader")
            return type == GL_VERTEX_SHADER ? 11 : 12
        }
        api.glGetVertexAttribPointerv = { _, _, pointer in
            GLRecorder.shared.calls.append("glGetVertexAttribPointerv")
            pointer![0] = UnsafeMutableRawPointer(bitPattern: 0x1234)
        }
        api.glUniform3fv = { _, count, values in
            GLRecorder.shared.calls.append("glUniform3fv")
            GLRecorder.shared.floats += (0..<Int(count) * 3).map { values![$0] }
        }
    }
}

/// Serialized: the fake GL records into one global.
@Suite(.serialized) struct GLShimTests {

    var recorder: GLRecorder { GLRecorder.shared }

    // MARK: Table

    @Test func tableListsEveryImportButGetString() throws {
        let count = rt_gl_function_count()
        #expect(count == 139)
        var names: [String: (parameters: String, result: CChar)] = [:]
        for index in 0..<count {
            let function = try #require(rt_gl_function_at(index)).pointee
            names[String(cString: function.name)] = (String(cString: function.parameters), function.result)
        }
        #expect(names.count == Int(count))
        #expect(names["glClearColor"]?.parameters == "ffff")
        #expect(names["glBufferData"]?.parameters == "iiii")
        #expect(names["glTexParameterf"]?.parameters == "iif")
        #expect(names["glCreateShader"]?.result == CChar(UInt8(ascii: "i")))
        #expect(names["glFlush"]?.result == CChar(UInt8(ascii: "v")))
        #expect(names["glGetString"] == nil, "the engine copies the string into the guest")
        #expect(names["glShaderBinary"] == nil && names["glReleaseShaderCompiler"] == nil, "not in WebGL 1")
        #expect(rt_gl_function_at(count) == nil)
    }

    @Test func apiLoadsByName() {
        var api = rt_gl_api()
        var asked: [String] = []
        let missing = withUnsafeMutablePointer(to: &asked) { asked in
            rt_gl_api_load(&api, { name, user in
                let name = String(cString: name!)
                user!.assumingMemoryBound(to: [String].self).pointee.append(name)
                // Everything but one function is found.
                return name == "glFinish" ? nil : UnsafeMutableRawPointer(bitPattern: 0x10)
            }, asked)
        }
        #expect(missing == 1)
        #expect(asked.count == 140, "glGetString too")
        #expect(asked.contains("glGetString"))
        #expect(api.glFinish == nil)
        #expect(api.glClear != nil)
    }

    // MARK: Pointers

    @Test func readsComeFromGuestMemory() {
        let fixture = GLFixture()
        fixture.write([1, 2, 3, 4, 5], at: 16)
        fixture.call { rt_gl_glBufferData($0, GL_ARRAY_BUFFER, 5, 16, GL_STATIC_DRAW) }
        #expect(recorder.bytes == [[1, 2, 3, 4, 5]])
        #expect(recorder.pointers == [UnsafeRawPointer(fixture.memory + 16)], "no copy")
        #expect(fixture.context.trapped == 0)

        // Null data only reserves the store.
        fixture.call { rt_gl_glBufferData($0, GL_ARRAY_BUFFER, 1 << 20, 0, GL_STATIC_DRAW) }
        #expect(recorder.pointers.last == .some(nil))
        #expect(fixture.context.trapped == 0)
    }

    @Test func readsPastTheEndTrap() {
        let fixture = GLFixture(size: 64)
        fixture.call { rt_gl_glBufferData($0, GL_ARRAY_BUFFER, 8, 56, GL_STATIC_DRAW) }
        #expect(recorder.calls == ["glBufferData"], "exactly to the end")
        fixture.call { rt_gl_glBufferData($0, GL_ARRAY_BUFFER, 9, 56, GL_STATIC_DRAW) }
        #expect(fixture.context.trapped == 1)
        #expect(recorder.calls == ["glBufferData"], "GL isn't called")

        // Once trapped, nothing runs: the engine is about to stop the guest.
        fixture.call { rt_gl_glClearColor($0, 0, 0, 0, 0) }
        #expect(recorder.calls == ["glBufferData"])
    }

    @Test func offsetsAndSizesDontWrap() {
        let fixture = GLFixture(size: 64)
        fixture.call { rt_gl_glBufferData($0, GL_ARRAY_BUFFER, 16, 0xFFFF_FFF8, GL_STATIC_DRAW) }
        #expect(fixture.context.trapped == 1)

        // A negative size is GL's error, not a trap.
        let negative = GLFixture(size: 64)
        negative.call { rt_gl_glBufferData($0, GL_ARRAY_BUFFER, UInt32(bitPattern: -1), 8, GL_STATIC_DRAW) }
        #expect(negative.context.trapped == 0)
        #expect(recorder.calls.isEmpty)
        #expect(negative.call { rt_gl_glGetError($0) } == GL_INVALID_VALUE)
    }

    @Test func writesGoToGuestMemory() {
        let fixture = GLFixture()
        fixture.call { rt_gl_glGenBuffers($0, 2, 32) }
        #expect(fixture.read32(32) == 100)
        #expect(fixture.read32(36) == 101)

        fixture.call { rt_gl_glGenBuffers($0, 2, 250) }
        #expect(fixture.context.trapped == 1, "8 bytes don't fit at 250 of 256")
    }

    @Test func stringsNeedATerminatorInsideMemory() {
        let fixture = GLFixture(size: 32)
        fixture.write(Array("u_color".utf8) + [0], at: 4)
        let location = fixture.call { rt_gl_glGetUniformLocation($0, 1, 4) }
        #expect(location == UInt32(bitPattern: -1), "a GLint result keeps its bits")
        #expect(recorder.strings == ["u_color"])

        fixture.write(Array("abcd".utf8), at: 28)
        _ = fixture.call { rt_gl_glGetUniformLocation($0, 1, 28) }
        #expect(fixture.context.trapped == 1, "runs off the end")
        #expect(recorder.calls == ["glGetUniformLocation"])
    }

    @Test func shaderSourcesBecomeHostPointersWithLengths() {
        let fixture = GLFixture()
        fixture.write(Array("void main".utf8) + [0], at: 100)
        fixture.write(Array("() {}XXXX".utf8), at: 120)
        // The guest's array of two offsets, and of two lengths.
        fixture.write32(100, at: 8)
        fixture.write32(120, at: 12)
        fixture.write32(UInt32(bitPattern: -1), at: 16)   // to the terminator
        fixture.write32(5, at: 20)
        fixture.call { rt_gl_glShaderSource($0, 1, 2, 8, 16) }
        #expect(recorder.strings == ["void main", "() {}"])

        // No lengths: both are terminated strings.
        fixture.write([0], at: 129)
        fixture.call { rt_gl_glShaderSource($0, 1, 2, 8, 0) }
        #expect(recorder.strings.suffix(2) == ["void main", "() {}XXXX"])
        #expect(fixture.context.trapped == 0)

        // A string pointer outside memory.
        fixture.write32(4096, at: 12)
        fixture.call { rt_gl_glShaderSource($0, 1, 2, 8, 0) }
        #expect(fixture.context.trapped == 1)
        #expect(recorder.calls.count == 2)
    }

    // MARK: WebGL rules

    @Test func attributesNeedABuffer() {
        let fixture = GLFixture()
        // No ARRAY_BUFFER bound: the "pointer" would be a host address.
        fixture.call { rt_gl_glVertexAttribPointer($0, 0, 3, GL_FLOAT, 0, 12, 24) }
        #expect(recorder.calls.isEmpty)
        #expect(fixture.call { rt_gl_glGetError($0) } == GL_INVALID_OPERATION)
        #expect(recorder.calls.isEmpty, "the shim's error comes first")

        recorder.error = GL_OUT_OF_MEMORY
        #expect(fixture.call { rt_gl_glGetError($0) } == GL_OUT_OF_MEMORY, "then GL's own")

        fixture.call { rt_gl_glBindBuffer($0, GL_ARRAY_BUFFER, 5) }
        fixture.call { rt_gl_glVertexAttribPointer($0, 0, 3, GL_FLOAT, 0, 12, 24) }
        #expect(recorder.calls.suffix(2) == ["glBindBuffer", "glVertexAttribPointer"])
        #expect(recorder.pointers == [UnsafeRawPointer(bitPattern: 24)], "an offset, passed as is")

        fixture.call { rt_gl_glVertexAttribPointer($0, 32, 3, GL_FLOAT, 0, 12, 0) }
        recorder.error = 0
        #expect(fixture.call { rt_gl_glGetError($0) } == GL_INVALID_VALUE, "past the attributes the shim tracks")
    }

    @Test func drawsNeedEveryEnabledAttributeBuffered() {
        let fixture = GLFixture()
        fixture.call { rt_gl_glEnableVertexAttribArray($0, 1) }
        fixture.call { rt_gl_glDrawArrays($0, GL_TRIANGLES, 0, 3) }
        #expect(!recorder.calls.contains("glDrawArrays"))
        #expect(fixture.call { rt_gl_glGetError($0) } == GL_INVALID_OPERATION)

        fixture.call { rt_gl_glBindBuffer($0, GL_ARRAY_BUFFER, 5) }
        fixture.call { rt_gl_glVertexAttribPointer($0, 1, 2, GL_FLOAT, 0, 0, 0) }
        // The attribute keeps its buffer after ARRAY_BUFFER is unbound.
        fixture.call { rt_gl_glBindBuffer($0, GL_ARRAY_BUFFER, 0) }
        fixture.call { rt_gl_glDrawArrays($0, GL_TRIANGLES, 0, 3) }
        #expect(recorder.calls.last == "glDrawArrays")

        // Deleting the buffer unbinds it from the attribute too.
        fixture.write32(5, at: 40)
        fixture.call { rt_gl_glDeleteBuffers($0, 1, 40) }
        fixture.call { rt_gl_glDrawArrays($0, GL_TRIANGLES, 0, 3) }
        #expect(recorder.calls.last == "glDeleteBuffers")
        #expect(fixture.call { rt_gl_glGetError($0) } == GL_INVALID_OPERATION)

        // Disabled attributes don't count.
        fixture.call { rt_gl_glDisableVertexAttribArray($0, 1) }
        fixture.call { rt_gl_glDrawArrays($0, GL_TRIANGLES, 0, 3) }
        #expect(recorder.calls.last == "glDrawArrays")
    }

    @Test func indexedDrawsNeedAnElementBuffer() {
        let fixture = GLFixture()
        fixture.call { rt_gl_glDrawElements($0, GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, 12) }
        #expect(recorder.calls.isEmpty)
        #expect(fixture.call { rt_gl_glGetError($0) } == GL_INVALID_OPERATION)

        fixture.call { rt_gl_glBindBuffer($0, GL_ELEMENT_ARRAY_BUFFER, 9) }
        fixture.call { rt_gl_glDrawElements($0, GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, 12) }
        #expect(recorder.calls.last == "glDrawElements")
        #expect(recorder.pointers == [UnsafeRawPointer(bitPattern: 12)])

        fixture.write32(9, at: 40)
        fixture.call { rt_gl_glDeleteBuffers($0, 1, 40) }
        fixture.call { rt_gl_glDrawElements($0, GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, 12) }
        #expect(recorder.calls.last == "glDeleteBuffers")
    }

    @Test func contextInitForgetsBindings() {
        let fixture = GLFixture()
        fixture.call { rt_gl_glBindBuffer($0, GL_ELEMENT_ARRAY_BUFFER, 9) }
        // A lost context: its buffers are gone.
        rt_gl_context_init(&fixture.context)
        fixture.context.base = fixture.memory
        fixture.context.size = UInt64(fixture.size)
        fixture.call { rt_gl_glDrawElements($0, GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, 0) }
        #expect(recorder.calls == ["glBindBuffer"])
    }

    // MARK: Sizes GL computes

    @Test func imagesAreSizedByFormatTypeAndAlignment() {
        // 3×2 RGB bytes: rows of 9, padded to 12 except the last: 21 bytes.
        let fixture = GLFixture(size: 64)
        func upload(_ offset: UInt32) {
            fixture.call {
                rt_gl_glTexImage2D($0, GL_TEXTURE_2D, 0, GL_RGB, 3, 2, 0, GL_RGB, GL_UNSIGNED_BYTE, offset)
            }
        }
        upload(43)
        #expect(recorder.calls == ["glTexImage2D"], "21 bytes end at 64")
        upload(44)
        #expect(fixture.context.trapped == 1)

        // Alignment 1: 18 bytes.
        let packed = GLFixture(size: 64)
        packed.call { rt_gl_glPixelStorei($0, GL_UNPACK_ALIGNMENT, 1) }
        packed.call { rt_gl_glTexImage2D($0, GL_TEXTURE_2D, 0, GL_RGB, 3, 2, 0, GL_RGB, GL_UNSIGNED_BYTE, 46) }
        #expect(packed.context.trapped == 0)
        #expect(recorder.calls == ["glPixelStorei", "glTexImage2D"])

        // No pixels: storage only, whatever the size.
        packed.call { rt_gl_glTexImage2D($0, GL_TEXTURE_2D, 0, GL_RGBA, 4096, 4096, 0, GL_RGBA, GL_UNSIGNED_BYTE, 0) }
        #expect(recorder.pointers.last == .some(nil))

        // A format the shim can't size isn't passed on.
        packed.call { rt_gl_glTexImage2D($0, GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0, 0x1234, GL_UNSIGNED_BYTE, 8) }
        #expect(recorder.calls.count == 3)
        #expect(packed.call { rt_gl_glGetError($0) } == GL_INVALID_VALUE)
    }

    @Test func readPixelsWritesTheImage() {
        let fixture = GLFixture(size: 64)
        fixture.call { rt_gl_glReadPixels($0, 0, 0, 2, 2, GL_RGBA, GL_UNSIGNED_BYTE, 8) }
        #expect(fixture.read(8, 16) == [UInt8](repeating: 0xAB, count: 16))
        #expect(fixture.read(24, 1) == [0])
        fixture.call { rt_gl_glReadPixels($0, 0, 0, 4, 4, GL_RGBA, GL_UNSIGNED_BYTE, 8) }
        #expect(fixture.context.trapped == 1, "64 bytes don't fit at 8")
    }

    @Test func getWritesAsManyValuesAsTheNameHas() {
        let fixture = GLFixture(size: 64)
        fixture.call { rt_gl_glGetIntegerv($0, GL_VIEWPORT, 48) }
        #expect((0..<4).map { fixture.read32(48 + $0 * 4) } == [1, 2, 3, 4])
        fixture.call { rt_gl_glGetIntegerv($0, GL_MAX_TEXTURE_SIZE, 60) }
        #expect(fixture.read32(60) == 42, "one value fits in the last 4 bytes")

        let short = GLFixture(size: 64)
        short.call { rt_gl_glGetIntegerv($0, GL_VIEWPORT, 52) }
        #expect(short.context.trapped == 1)
    }

    @Test func resultsOfUnknownSizeDontWritePastWhatGLWrote() {
        // A vec2 uniform read into the last 12 bytes of memory: GL may write
        // up to 16 floats, so the shim lends it scratch space.
        let fixture = GLFixture(size: 64)
        fixture.write([UInt8](repeating: 0xEE, count: 12), at: 52)
        fixture.call { rt_gl_glGetUniformfv($0, 1, 0, 52) }
        #expect(fixture.context.trapped == 0)
        #expect(fixture.read32(52) == Float(1.5).bitPattern)
        #expect(fixture.read32(56) == Float(-2).bitPattern)
        #expect(fixture.read(60, 4) == [0xEE, 0xEE, 0xEE, 0xEE], "untouched")

        // With room for all 16, GL writes straight into guest memory.
        let roomy = GLFixture(size: 128)
        roomy.call { rt_gl_glGetUniformfv($0, 1, 0, 8) }
        #expect(roomy.read32(8) == Float(1.5).bitPattern)

        let outside = GLFixture(size: 64)
        outside.call { rt_gl_glGetUniformfv($0, 1, 0, 64) }
        #expect(outside.context.trapped == 1)
    }

    @Test func attributePointersComeBackAsOffsets() {
        let fixture = GLFixture(size: 64)
        fixture.write([UInt8](repeating: 0xEE, count: 8), at: 16)
        fixture.call { rt_gl_glGetVertexAttribPointerv($0, 0, GL_VERTEX_ATTRIB_ARRAY_POINTER, 16) }
        #expect(fixture.read32(16) == 0x1234)
        #expect(fixture.read(20, 4) == [0xEE, 0xEE, 0xEE, 0xEE], "4 bytes, not a host pointer's 8")
    }

    // MARK: By index

    @Test func callsByIndexUnpackSlots() throws {
        let fixture = GLFixture()
        func index(of name: String) throws -> UInt32 {
            try #require((0..<rt_gl_function_count()).first { String(cString: rt_gl_function_at($0)!.pointee.name) == name })
        }
        let clearColor = try index(of: "glClearColor")
        let slots = [Float(0.25), 0.5, 0.75, 1].map { UInt64($0.bitPattern) }
        #expect(fixture.call { rt_gl_call($0, clearColor, slots) } == 0)
        #expect(recorder.floats == [0.25, 0.5, 0.75, 1])

        let createShader = try index(of: "glCreateShader")
        #expect(fixture.call { rt_gl_call($0, createShader, [UInt64(GL_VERTEX_SHADER)]) } == 11)

        // Three vec3s from guest memory.
        let uniform = try index(of: "glUniform3fv")
        for (position, value) in (1...9).enumerated() {
            fixture.write32(Float(value).bitPattern, at: 64 + position * 4)
        }
        _ = fixture.call { rt_gl_call($0, uniform, [0, 3, 64]) }
        #expect(recorder.floats.suffix(9) == (1...9).map(Float.init))

        _ = fixture.call { rt_gl_call($0, 9999, []) }
        #expect(fixture.context.trapped == 1, "no such import")
    }
}
