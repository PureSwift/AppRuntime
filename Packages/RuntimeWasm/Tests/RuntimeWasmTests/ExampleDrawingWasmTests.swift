import Foundation
import Testing
import DynamicDrawing
import DynamicFiles
import DynamicUI
import RuntimeABI
import RuntimeDrawing
import RuntimeHost
import RuntimeNative
import RuntimeWasm

/// The example drawing app as App.wasm under WasmKit, over `RuntimeDrawing`
/// with the memory backend: canvases drawn when the test asks, their
/// drawings replayed into a recorder, text measured by the backend's
/// fonts, and a badge drawn into a bitmap and saved. Part of
/// `WasmShimTests`, which is serialized, since both use
/// `NativeRuntime.shared`.
extension WasmShimTests {

    /// Built by `Scripts/build-wasm.sh ExampleDrawing`; skipped without it.
    static var exampleDrawingURL: URL {
        exampleUIURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExampleDrawing/wasm32/App.wasm")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.exampleDrawingURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExampleDrawing"))
    func exampleDrawingInWasmMode() throws {
        let manager = Foundation.FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ExampleDrawing-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? manager.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")

        let native = NativeRuntime.shared
        native.capabilities = nil
        RendererProxy.register(WasmTestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        try HostFiles.configure(HostFiles.Configuration(directories: [.documents: documents.path], work: { $0() }, deliver: { $0() }))
        HostFilesModule.register(in: native)
        HostImages.reset()
        HostDrawing.reset()
        let backend = MemoryDrawingBackend()
        HostDrawing.backend = backend
        var redraws: [Int32] = []
        HostDrawing.canvasNeedsDisplay = { redraws.append($0) }
        HostDrawing.log = { _ in }
        HostDrawingModule.register(in: native)
        defer {
            HostDrawing.reset()
            HostImages.reset()
        }
        WasmTestRenderer.last = nil

        let app = try WasmApp(bytes: Array(try Data(contentsOf: Self.exampleDrawingURL)), runtime: native.runtime, capabilities: [])
        let contracts = try #require(WasmApp.contracts(of: app.module))
        #expect(contracts.first { $0.name == "org.pureswift.drawing.Canvas" }?.capability == nil)
        #expect(try app.start() == .ok)
        let renderer = try #require(WasmTestRenderer.last)

        func canvases() -> [Int32] {
            var found: [Int32] = []
            func walk(_ node: RenderNode) {
                if node.type == "Canvas", let identifier = node.props["canvas"]?.int { found.append(Int32(identifier)) }
                node.children.forEach(walk)
            }
            renderer.screen.map(walk)
            return found
        }
        func draw(_ identifier: Int32, width: Double, height: Double) throws -> [String] {
            let recorder = RecordingRenderer()
            let canvas = try #require(HostCanvas.canvas(for: identifier))
            #expect(canvas.play(width: width, height: height, scale: 2, into: recorder) == nil)
            return recorder.calls
        }

        // Three canvases: the gauge, the chart, and the star, a shape of the
        // app's own.
        let shown = canvases()
        #expect(shown.count == 3)
        #expect(renderer.screen?.first { $0.type == "Shape" } == nil)
        var gauge = try draw(shown[0], width: 120, height: 120)
        #expect(gauge.filter { $0.hasPrefix("stroke C") || $0.hasPrefix("stroke M") }.count == 2, "the track and the level")
        #expect(gauge.last == "text \"40%\" at 60 60 anchor 0.5 0.5")
        #expect(backend.fonts.contains { $0.size == 28 && $0.weight == .semibold })

        // Labels measured to fit their slots.
        let wide = try draw(shown[1], width: 200, height: 100)
        #expect(wide.filter { $0.hasPrefix("text") }.map { $0.split(separator: "\"")[1] } == ["Jan", "Feb", "Mar", "April"])
        let narrow = try draw(shown[1], width: 100, height: 100)
        #expect(narrow.filter { $0.hasPrefix("text") }.map { $0.split(separator: "\"")[1] } == ["Ja", "Fe", "Ma", "Ap"], "cut to what fits")

        let star = try draw(shown[2], width: 40, height: 40)
        #expect(star.count == 4 && star[2].hasPrefix("fill winding M 20 0 L"), "ten points round the middle")

        // More: the gauge asks to be drawn again, and draws the new level.
        renderer.send(try #require(renderer.screen?.button("More")), .tap)
        #expect(redraws.contains(shown[0]))
        gauge = try draw(shown[0], width: 120, height: 120)
        #expect(gauge.last == "text \"50%\" at 60 60 anchor 0.5 0.5")
        #expect(canvases() == shown, "the same canvases")

        // A badge drawn off screen, shown, and saved as a PNG.
        renderer.send(try #require(renderer.screen?.button("Make Badge")), .tap)
        let bitmap = try #require(backend.bitmaps.last)
        #expect(bitmap.pixelWidth == 128 && bitmap.pixelHeight == 128)
        #expect(bitmap.recorder.calls.first == "concatenate 2 0 0 2 0 0")
        #expect(bitmap.recorder.calls.contains("fill color 1 0.584 0 1"))
        #expect(bitmap.recorder.calls.last == "text \"50\" at 32 32 anchor 0.5 0.5")
        #expect(renderer.screen?.identified("status")?.props["text"] == "Saved badge.png, 6 bytes")
        #expect(try Data(contentsOf: documents.appendingPathComponent("badge.png")) == Data([0x89, 0x50, 0x4E, 0x47, 128, 128]))
        let badge = try #require(renderer.screen?.first { $0.type == "Image" })
        let identifier = try #require(badge.props["image"]?.int)
        let image = try #require(HostImages.image(Int32(identifier)))
        #expect(image.scale == 2)
    }
}
