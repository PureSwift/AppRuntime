import Foundation
import Testing
@testable import DynamicDrawing
import DynamicFiles
import DynamicRuntime
@testable import DynamicSwiftUI
import DynamicUI
import RuntimeDrawing
import RuntimeHost
import RuntimeNative

/// Records what a view graph sends, as a host's renderer would show it.
final class DrawingSink: RenderSink {

    var screen: RenderNode?

    func apply(_ tree: RenderNode) {
        screen = tree
    }

    func replace(_ id: RenderNode.ID, with subtree: RenderNode) {
        screen?.replace(id, with: subtree)
    }
}

extension RenderNode {

    func first(_ type: String) -> RenderNode? {
        if self.type == type { return self }
        for child in children {
            if let found = child.first(type) { return found }
        }
        return nil
    }
}

/// A PNG's signature and `IHDR`: enough for a header.
func drawingPNG(width: Int, height: Int) -> [UInt8] {
    func be(_ value: Int) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
    return [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
        + be(width) + be(height) + [8, 6, 0, 0, 0]
}

/// Read on every update: `update()` evaluates the whole tree.
final class Shelf: @unchecked Sendable {
    var showsPicture: Bool = true
    var picture: Image?
}

struct ShelfView: View {
    let shelf: Shelf
    var body: some View {
        VStack {
            if shelf.showsPicture, let picture = shelf.picture {
                picture.resizable().scaledToFit()
            }
            Text("shelf")
        }
    }
}

/// The guest's `Image` sources, through the native runtime, over
/// `RuntimeDrawing` with `MemoryImageDecoder` and real files.
///
/// Serialized: `HostImages`, `HostFiles` and the native runtime are shared.
@Suite(.serialized) final class DynamicDrawingTests {

    let root: URL

    let decoder = MemoryImageDecoder()

    init() throws {
        root = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("DynamicDrawingTests-\(UUID().uuidString)")
        let native = NativeRuntime.shared
        native.capabilities = nil
        try HostFiles.configure(HostFiles.Configuration(directories: [
            .documents: root.appendingPathComponent("Documents").path,
            .caches: root.appendingPathComponent("Caches").path,
            .temporary: root.appendingPathComponent("tmp").path,
        ], work: { $0() }, deliver: { $0() }))
        HostFilesModule.register(in: native)
        HostImages.reset()
        HostImages.decoder = decoder
        HostImages.work = { $0() }
        HostImages.deliver = { $0() }
        HostImages.log = { _ in }
        HostDrawing.reset()
        HostDrawing.log = { _ in }
        HostDrawingModule.register(in: native)
    }

    deinit {
        HostImages.reset()
        HostDrawing.reset()
        try? Foundation.FileManager.default.removeItem(at: root)
    }

    func write(_ bytes: [UInt8], _ name: String) throws {
        try Data(bytes).write(to: root.appendingPathComponent("Documents").appendingPathComponent(name))
    }

    func host(_ image: Image) throws -> HostImage {
        let node = try #require(image.node)
        let identifier = try #require(node.props["image"]?.int)
        return try #require(HostImages.image(Int32(identifier)))
    }

    // MARK: The contract

    @Test func theContractNeedsNoCapability() {
        let image = DrawingImageProxy.descriptor
        #expect(image.name == "org.pureswift.drawing.Image")
        #expect(image.capability == nil)
        let keys = image.methods.map { $0.key }
        #expect(keys.count == 6)
        for name in ["open", "decode", "make", "formats", "identifier", "size"] {
            #expect(keys.contains { $0.hasPrefix(name) }, "\(name) in \(keys)")
        }
        #expect(DrawingCallbackProxy.descriptor.name == "org.pureswift.drawing.Callback")
        #expect(HostDrawingModule.contracts.count == 6, "the image and its callback, the canvas and its delegate, the bitmap and the font")
    }

    // MARK: Sources

    @Test func aFileImageReadsNothingUntilAsked() async throws {
        try write(drawingPNG(width: 4032, height: 3024), "photo.png")
        let image = Image(contentsOf: .documents / "photo.png")
        #expect(decoder.headers.isEmpty)
        let size = try await image.size
        #expect(size == Size(width: 4032, height: 3024))
        #expect(decoder.headers.count == 1)
        #expect(decoder.decodes.isEmpty, "the size is the header's")
        #expect(try host(image).maxPixelSize == 0)
    }

    @Test func aThumbnailCarriesItsCap() throws {
        let image = Image(contentsOf: .documents / "photo.png", maximumPixelSize: 64)
        #expect(try host(image).maxPixelSize == 64)
        #expect(try host(Image(data: [1], maximumPixelSize: -5)).maxPixelSize == 0)
    }

    @Test func bytesAndPixels() async throws {
        let bytes = Image(data: drawingPNG(width: 300, height: 200))
        #expect(try await bytes.size == Size(width: 300, height: 200))

        #expect(Image(pixels: [0, 0, 0], width: 1, height: 1) == nil, "bytes that don't match the size")
        #expect(Image(pixels: [], width: 0, height: 0) == nil)
        let swatch = try #require(Image(pixels: [UInt8](repeating: 255, count: 16), width: 2, height: 2, scale: 2))
        #expect(try await swatch.size == Size(width: 1, height: 1), "in points")
        #expect(try host(swatch).scale == 2)
    }

    @Test func failuresAreTheHosts() async throws {
        await #expect(throws: DrawingError.notFound) { try await Image(contentsOf: .documents / "none.png").size }
        await #expect(throws: DrawingError.undecodable) { try await Image(data: [1, 2, 3]).size }
        await #expect(throws: DrawingError.unavailable) { try await Image(systemName: "star").size }
        HostImages.decoder = nil
        #expect(Image.decodableTypes.isEmpty)
        await #expect(throws: DrawingError.unavailable) { try await Image(data: drawingPNG(width: 1, height: 1)).size }
    }

    @Test func theHostSaysWhatItDecodes() {
        #expect(Image.decodableTypes == ["image/png", "image/jpeg"])
    }

    @Test func aDocumentIsReadThroughItsAccess() async throws {
        let picked = root.appendingPathComponent("picked.png")
        try Data(drawingPNG(width: 30, height: 20)).write(to: picked)
        let directory = HostFiles.grant(HostFiles.Grant(path: picked.path, kind: .file, isWritable: false))
        let image = Image(contentsOf: FilePath(directory))
        #expect(try await image.size == Size(width: 30, height: 20))

        HostFiles.revoke(directory)
        let later = Image(contentsOf: FilePath(directory))
        await #expect(throws: DrawingError.notPermitted) { try await later.size }
    }

    // MARK: In a tree

    @Test func theTreeNamesTheImageAndHoldsIt() throws {
        let shelf = Shelf()
        shelf.picture = Image(data: drawingPNG(width: 10, height: 10))
        let identifier = try #require(try host(shelf.picture!).identifier())
        let sink = DrawingSink()
        let graph = ViewGraph(ShelfView(shelf: shelf), sink: sink)
        graph.update()
        let node = try #require(sink.screen?.first("Image"))
        #expect(node.props["image"] == .int(Int(identifier)))
        #expect(node.modifiers.first?.kind == "aspectRatio")

        shelf.picture = nil
        #expect(HostImages.image(identifier) != nil, "the tree sent still shows it")
        shelf.showsPicture = false
        graph.update()
        #expect(HostImages.image(identifier) == nil, "the host's image goes with the last copy")
    }
}

extension Image {

    /// The node an image makes, for checking its props.
    var node: RenderNode? {
        let sink = DrawingSink()
        let graph = ViewGraph(self, sink: sink)
        graph.update()
        return sink.screen
    }
}
