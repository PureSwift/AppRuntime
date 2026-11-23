import Foundation
import Testing
import DynamicDrawing
import DynamicFiles
import DynamicRuntime
import RuntimeHost
import RuntimeNative
@testable import RuntimeDrawing

/// A PNG's signature and `IHDR`: enough for a header.
func pngHeader(width: Int, height: Int) -> [UInt8] {
    func be(_ value: Int) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
    return [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
        + be(width) + be(height) + [8, 6, 0, 0, 0]
}

/// A JPEG's start, an APP0 segment, and a baseline start of frame.
func jpegHeader(width: Int, height: Int) -> [UInt8] {
    [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46,
     0xFF, 0xC0, 0x00, 0x11, 0x08,
     UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF),
     0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]
}

/// What a `size` call was answered with.
final class SizeAnswer: DrawingCallback {

    var measured: (width: Float, height: Float, scale: Float)?

    var failed: DrawingError?

    var answers = 0

    func didRead(_ data: [UInt8]) {
        answers += 1
    }

    func didMeasure(width: Float, height: Float, scale: Float) {
        answers += 1
        measured = (width, height, scale)
    }

    func didFail(_ code: Int32, message: String) {
        answers += 1
        failed = DrawingError(rawValue: code)
    }
}

/// `HostImages` over `MemoryImageDecoder`, with files in a container of
/// the test's own and decoder work run when the test says.
///
/// Serialized: `HostImages` and `HostFiles` are shared.
@Suite(.serialized) final class RuntimeDrawingTests {

    let root: URL

    let decoder = MemoryImageDecoder()

    /// Decoder work, run by `runWork()`.
    nonisolated(unsafe) static var queued: [@Sendable () -> Void] = []

    nonisolated(unsafe) static var logged: [String] = []

    init() throws {
        root = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("RuntimeDrawingTests-\(UUID().uuidString)")
        try HostFiles.configure(HostFiles.Configuration(directories: [
            .documents: root.appendingPathComponent("Documents").path,
            .caches: root.appendingPathComponent("Caches").path,
            .temporary: root.appendingPathComponent("tmp").path,
        ], work: { $0() }, deliver: { $0() }))
        HostImages.reset()
        HostImages.decoder = decoder
        HostImages.work = { RuntimeDrawingTests.queued.append($0) }
        HostImages.deliver = { $0() }
        HostImages.log = { RuntimeDrawingTests.logged.append($0) }
        Self.queued = []
        Self.logged = []
    }

    deinit {
        HostImages.reset()
        try? Foundation.FileManager.default.removeItem(at: root)
    }

    func runWork() {
        while !Self.queued.isEmpty {
            Self.queued.removeFirst()()
        }
    }

    func write(_ bytes: [UInt8], _ name: String) throws {
        let url = root.appendingPathComponent("Documents").appendingPathComponent(name)
        try Data(bytes).write(to: url)
    }

    // MARK: Sizes

    @Test func sizesRoundUpToAPowerOfTwoAndAreCapped() {
        #expect(HostImages.decodeSize(forPixelSize: 300, longerSide: 4032, maxPixelSize: 0) == 512)
        #expect(HostImages.decodeSize(forPixelSize: 512, longerSide: 4032, maxPixelSize: 0) == 512)
        #expect(HostImages.decodeSize(forPixelSize: 513, longerSide: 4032, maxPixelSize: 0) == 1024)
        #expect(HostImages.decodeSize(forPixelSize: 3000, longerSide: 4032, maxPixelSize: 0) == 4032, "never more than it has")
        #expect(HostImages.decodeSize(forPixelSize: 3000, longerSide: 4032, maxPixelSize: 256) == 256, "nor more than its cap")
        #expect(HostImages.decodeSize(forPixelSize: 0, longerSide: 4032, maxPixelSize: 0) == 1)
        HostImages.maximumSide = 2048
        #expect(HostImages.decodeSize(forPixelSize: 3000, longerSide: 4032, maxPixelSize: 0) == 2048, "nor more than the host takes")
    }

    @Test func theTestDecoderReadsPNGAndJPEGHeaders() throws {
        #expect(try MemoryImageDecoder.header(of: pngHeader(width: 4032, height: 3024)) == HostImageHeader(pixelWidth: 4032, pixelHeight: 3024))
        #expect(try MemoryImageDecoder.header(of: jpegHeader(width: 640, height: 480)) == HostImageHeader(pixelWidth: 640, pixelHeight: 480))
        #expect(throws: DrawingError.undecodable) { try MemoryImageDecoder.header(of: [1, 2, 3]) }
        #expect(throws: DrawingError.undecodable) { try MemoryImageDecoder.header(of: pngHeader(width: 0, height: 3)) }
    }

    // MARK: The contract

    @Test func aFilesSizeIsItsHeaderRead() throws {
        try write(pngHeader(width: 4032, height: 3024), "photo.png")
        let image = HostImage.open(FileDirectory.documents.rawValue, path: "photo.png", maxPixelSize: 0)
        #expect(decoder.headers.isEmpty, "making one reads nothing")
        let answer = SizeAnswer()
        image.size(answer)
        #expect(answer.answers == 0, "the header is read off the main thread")
        runWork()
        #expect(answer.measured?.width == 4032)
        #expect(answer.measured?.height == 3024)
        #expect(answer.measured?.scale == 1)

        let again = SizeAnswer()
        image.size(again)
        #expect(again.measured?.width == 4032, "answered from the header it read")
        #expect(decoder.headers.count == 1)
        #expect(decoder.decodes.isEmpty, "nothing was decoded")
    }

    @Test func aMissingFileOrBytesThatArentAnImageFail() throws {
        let missing = HostImage.open(FileDirectory.documents.rawValue, path: "none.png", maxPixelSize: 0)
        let answer = SizeAnswer()
        missing.size(answer)
        #expect(answer.failed == .notFound)

        let junk = HostImage.decode([1, 2, 3, 4], maxPixelSize: 0)
        let junkAnswer = SizeAnswer()
        junk.size(junkAnswer)
        runWork()
        #expect(junkAnswer.failed == .undecodable)
        let line = try #require(Self.logged.last)
        #expect(line.contains("not an image"))

        var decodeFailure: DrawingError?
        junk.decoded(forPixelSize: 100) { result in
            if case .failure(let error) = result { decodeFailure = error }
        }
        #expect(decodeFailure == .undecodable)
        #expect(Self.logged.count == 2, "each image is said once")
    }

    @Test func pixelsHaveTheirSizeAndScale() {
        #expect(HostImage.make(pixels: [UInt8](repeating: 0, count: 15), width: 2, height: 2, scale: 2) == nil, "bytes that don't match")
        #expect(HostImage.make(pixels: [], width: 0, height: 0, scale: 1) == nil)
        HostImages.maximumSide = 1
        #expect(HostImage.make(pixels: [UInt8](repeating: 0, count: 16), width: 2, height: 2, scale: 2) == nil, "a size the host refuses")
        HostImages.maximumSide = 16384
        let image = HostImage.make(pixels: [UInt8](repeating: 0, count: 16), width: 2, height: 2, scale: 2)
        let answer = SizeAnswer()
        image?.size(answer)
        #expect(answer.measured?.width == 1, "in points")
        #expect(answer.measured?.scale == 2)
        #expect(decoder.headers.isEmpty)

        var decoded: HostDecodedImage?
        image?.decoded(forPixelSize: 400) { decoded = try? $0.get() }
        runWork()
        #expect(decoded?.pixelWidth == 2)
    }

    @Test func withoutADecoderNothingIsMeasured() throws {
        HostImages.decoder = nil
        #expect(HostImage.formats().isEmpty)
        let image = HostImage.decode(pngHeader(width: 10, height: 10), maxPixelSize: 0)
        let answer = SizeAnswer()
        image.size(answer)
        #expect(answer.failed == .unavailable)
        HostImages.decoder = decoder
        #expect(HostImage.formats() == ["image/png", "image/jpeg"])
        let later = SizeAnswer()
        image.size(later)
        runWork()
        #expect(later.measured?.width == 10, "a decoder set later is used")
    }

    // MARK: Decoding

    @Test func itsDecodedForTheSizeDrawnAndKeepsTheLargest() throws {
        try write(pngHeader(width: 4032, height: 3024), "photo.png")
        let image = HostImage.open(FileDirectory.documents.rawValue, path: "photo.png", maxPixelSize: 0)
        var first: HostDecodedImage?
        image.decoded(forPixelSize: 300) { first = try? $0.get() }
        runWork()
        #expect(first?.pixelWidth == 512)
        #expect(decoder.decodes.map { $0.maxPixelSize } == [512])

        var small: HostDecodedImage?
        image.decoded(forPixelSize: 100) { small = try? $0.get() }
        #expect(small?.pixelWidth == 512, "what it holds is enough: no decode")
        #expect(decoder.decodes.count == 1)

        var zoomed: HostDecodedImage?
        image.decoded(forPixelSize: 1800) { zoomed = try? $0.get() }
        #expect(zoomed == nil)
        #expect(image.decodedImage?.pixelWidth == 512, "shown scaled meanwhile")
        runWork()
        #expect(zoomed?.pixelWidth == 2048)
        #expect(image.decodedImage?.pixelWidth == 2048)
        #expect(decoder.decodes.map { $0.maxPixelSize } == [512, 2048])
    }

    @Test func oneDecodeRunsAtATime() throws {
        try write(pngHeader(width: 4000, height: 1000), "wide.png")
        let image = HostImage.open(FileDirectory.documents.rawValue, path: "wide.png", maxPixelSize: 0)
        var header: HostImageHeader?
        image.header { header = try? $0.get() }
        runWork()
        #expect(header == HostImageHeader(pixelWidth: 4000, pixelHeight: 1000))

        var answers: [Int] = []
        image.decoded(forPixelSize: 200) { answers.append((try? $0.get())?.pixelWidth ?? 0) }
        image.decoded(forPixelSize: 900) { answers.append((try? $0.get())?.pixelWidth ?? 0) }
        image.decoded(forPixelSize: 3000) { answers.append((try? $0.get())?.pixelWidth ?? 0) }
        #expect(Self.queued.count == 1, "the first is decoding; the others wait")
        runWork()
        #expect(decoder.decodes.map { $0.maxPixelSize } == [256, 4000], "the next is for the largest waiting")
        #expect(answers == [256, 4000, 4000])
    }

    @Test func aCappedImageIsNeverDecodedLarger() throws {
        try write(pngHeader(width: 4032, height: 3024), "photo.png")
        let image = HostImage.open(FileDirectory.documents.rawValue, path: "photo.png", maxPixelSize: 64)
        var decoded: HostDecodedImage?
        image.decoded(forPixelSize: 3000) { decoded = try? $0.get() }
        runWork()
        #expect(decoded?.pixelWidth == 64)
        image.decoded(forPixelSize: 4000) { decoded = try? $0.get() }
        #expect(decoder.decodes.count == 1)
    }

    @Test func trimDropsWhatNothingAskedFor() throws {
        try write(pngHeader(width: 100, height: 100), "a.png")
        let shown = HostImage.open(FileDirectory.documents.rawValue, path: "a.png", maxPixelSize: 0)
        let hidden = HostImage.open(FileDirectory.documents.rawValue, path: "a.png", maxPixelSize: 0)
        shown.decoded(forPixelSize: 100) { _ in }
        hidden.decoded(forPixelSize: 100) { _ in }
        runWork()
        HostImages.trim()
        #expect(shown.decodedImage != nil, "both were asked for since the last trim")
        shown.decoded(forPixelSize: 100) { _ in }
        HostImages.trim()
        #expect(shown.decodedImage != nil)
        #expect(hidden.decodedImage == nil)
    }

    @Test func anImageTheGuestReleasedIsGone() throws {
        try write(pngHeader(width: 100, height: 100), "a.png")
        var image: HostImage? = HostImage.open(FileDirectory.documents.rawValue, path: "a.png", maxPixelSize: 0)
        let identifier = try #require(image?.identifier())
        #expect(HostImages.image(identifier) === image)
        var answered = false
        image?.decoded(forPixelSize: 50) { _ in answered = true }
        image = nil
        #expect(HostImages.image(identifier) == nil)
        runWork()
        #expect(!answered, "a decode for a released image is dropped")
    }

    @Test func aDocumentLetGoOfIsNotPermitted() throws {
        let picked = root.appendingPathComponent("picked.png")
        try Data(pngHeader(width: 30, height: 20)).write(to: picked)
        let directory = HostFiles.grant(HostFiles.Grant(path: picked.path, kind: .file, isWritable: false))
        let image = HostImage.open(directory.rawValue, path: "", maxPixelSize: 0)
        let answer = SizeAnswer()
        image.size(answer)
        runWork()
        #expect(answer.measured?.width == 30)

        HostFiles.revoke(directory)
        var failure: DrawingError?
        image.decoded(forPixelSize: 30) { result in
            if case .failure(let error) = result { failure = error }
        }
        #expect(failure == .notPermitted)
    }
}
