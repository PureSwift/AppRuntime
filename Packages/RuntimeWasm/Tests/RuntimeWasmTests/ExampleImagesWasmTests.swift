import Foundation
import Testing
import DynamicDrawing
import DynamicFiles
import DynamicUI
import RuntimeABI
import RuntimeDocuments
import RuntimeDrawing
import RuntimeHost
import RuntimeNative
import RuntimeWasm

/// The example images app as App.wasm under WasmKit: a file it writes and
/// one the user picks, read and measured by the host's decoder, shown in a
/// scroll view that zooms, with a thumbnail and a swatch of pixels, in an
/// Embedded guest. The decoder is `MemoryImageDecoder`, over real files.
/// Part of `WasmShimTests`, which is serialized, since both use
/// `NativeRuntime.shared`.
extension WasmShimTests {

    /// Built by `Scripts/build-wasm.sh ExampleImages`; skipped without it.
    static var exampleImagesURL: URL {
        exampleUIURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ExampleImages/wasm32/App.wasm")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: WasmShimTests.exampleImagesURL.path), "Build the wasm slice first: Scripts/build-wasm.sh ExampleImages"))
    func exampleImagesInWasmMode() throws {
        let manager = Foundation.FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ExampleImages-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? manager.removeItem(at: root) }
        // A JPEG the user has: a start of frame is all the test decoder reads.
        let holiday = root.appendingPathComponent("holiday.jpg")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0xE0, 0x02, 0x80,
                  0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]).write(to: holiday)

        let native = NativeRuntime.shared
        native.capabilities = nil
        RendererProxy.register(WasmTestRenderer.self, in: native)
        RendererDelegateProxy.registerInterface(in: native)
        let container = root.appendingPathComponent("Container")
        try HostFiles.configure(HostFiles.Configuration(directories: [
            .documents: container.appendingPathComponent("Documents").path,
            .caches: container.appendingPathComponent("Caches").path,
            .temporary: container.appendingPathComponent("tmp").path,
        ], work: { $0() }, deliver: { $0() }))
        HostFilesModule.register(in: native)
        let presenter = WasmTestPresenter()
        HostDocuments.reset()
        HostDocuments.presenter = presenter
        HostDocuments.deliver = { $0() }
        HostDocumentsModule.register(in: native)
        defer { HostDocuments.reset() }
        let decoder = MemoryImageDecoder()
        HostImages.reset()
        HostImages.decoder = decoder
        HostImages.work = { $0() }
        HostImages.deliver = { $0() }
        HostDrawingModule.register(in: native)
        defer { HostImages.reset() }
        WasmTestRenderer.last = nil

        let bytes = Array(try Data(contentsOf: Self.exampleImagesURL))
        let app = try WasmApp(bytes: bytes, runtime: native.runtime, capabilities: [.userFiles])
        let contracts = try #require(WasmApp.contracts(of: app.module))
        let image = try #require(contracts.first { $0.name == "org.pureswift.drawing.Image" })
        #expect(image.capability == nil)
        #expect(try app.start() == .ok)
        let renderer = try #require(WasmTestRenderer.last)
        func text(_ identifier: String) -> PropValue? {
            renderer.screen?.identified(identifier)?.props["text"]
        }
        func images() -> [RenderNode] {
            var found: [RenderNode] = []
            func walk(_ node: RenderNode) {
                if node.type == "Image" { found.append(node) }
                node.children.forEach(walk)
            }
            renderer.screen.map(walk)
            return found
        }
        func host(_ node: RenderNode) throws -> HostImage {
            let identifier = try #require(node.props["image"]?.int)
            return try #require(HostImages.image(Int32(identifier)))
        }
        func scroll() throws -> RenderNode {
            try #require(renderer.screen?.first { $0.type == "ScrollView" })
        }

        // The sample it wrote, measured from its header.
        #expect(text("name") == "sample.png")
        #expect(text("size") == "40 × 30")
        #expect(decoder.decodes.isEmpty, "nothing is decoded until it's drawn")
        var shown = images()
        #expect(shown.count == 3)
        #expect(shown[0].props["resizable"] == true)
        #expect(shown[0].modifiers.map(\.kind) == ["aspectRatio", "accessibilityLabel"])
        #expect(shown[0].modifiers[0].args["contentMode"] == "fit")
        #expect(try host(shown[1]).maxPixelSize == 64, "the thumbnail")
        #expect(shown[1].modifiers.map(\.kind) == ["aspectRatio", "frame", "clipped"])
        #expect(try host(shown[2]).scale == 2, "the swatch")

        // The renderer draws it: decoded for what it covers, never larger than it is.
        // (The test holds no host image past its use: the guest's release is checked below.)
        var decoded: HostDecodedImage?
        try host(shown[0]).decoded(forPixelSize: 600) { decoded = try? $0.get() }
        #expect(decoded?.pixelWidth == 40)
        #expect(decoder.decodes.map(\.maxPixelSize) == [40])

        // The scroll view zooms in the host; the guest hears the scale.
        var node = try scroll()
        #expect(node.props["axes"] == "both")
        #expect(node.props["minZoom"] == 1.0)
        #expect(node.props["maxZoom"] == 8.0)
        #expect(node.props["zoom"] == 1.0)
        renderer.send(node, .change, .double(3))
        #expect(text("zoom") == "Zoom 300%")
        node = try scroll()
        #expect(node.props["zoom"] == 3.0)
        renderer.send(try #require(renderer.screen?.button("Fit")), .tap)
        #expect(text("zoom") == "Zoom 100%")
        #expect(try scroll().props["zoom"] == 1.0)

        // The user picks an image: read through the document's access.
        let before = try #require(shown[0].props["image"]?.int)
        presenter.picked = [HostDocument(path: holiday.path)]
        renderer.send(try #require(renderer.screen?.button("Open an Image")), .tap)
        #expect(presenter.calls.count == 1)
        #expect(text("name") == "holiday.jpg")
        #expect(text("size") == "640 × 480")
        #expect(text("status") == "Opened holiday.jpg")
        shown = images()
        #expect(shown[0].props["image"]?.int != before)
        #expect(HostImages.image(Int32(before)) == nil, "the sample's image went with the tree that showed it")
        try host(shown[0]).decoded(forPixelSize: 300) { decoded = try? $0.get() }
        #expect(decoded?.pixelWidth == 512)
        #expect(decoded?.pixelHeight == 384)
    }
}
