import DynamicDrawing
import Foundation

/// A decoder for tests: it reads the sizes in PNG and JPEG headers, and
/// "decodes" to a `MemoryImageDecoder.Decode` that says what was asked of
/// it. It applies no orientation. It isn't a default: a host sets its
/// platform's.
public final class MemoryImageDecoder: ImageDecoder, @unchecked Sendable {

    /// What a decode made: the size it fits in, and what it was decoded from.
    public final class Decode {

        public let source: HostImageSource

        public let maxPixelSize: Int

        init(source: HostImageSource, maxPixelSize: Int) {
            self.source = source
            self.maxPixelSize = maxPixelSize
        }
    }

    private let lock = NSLock()

    private var headerReads: [HostImageSource] = []

    private var decodeRequests: [(source: HostImageSource, maxPixelSize: Int)] = []

    public let formats: [String]

    public init(formats: [String] = ["image/png", "image/jpeg"]) {
        self.formats = formats
    }

    /// Every header read, in order.
    public var headers: [HostImageSource] {
        lock.lock()
        defer { lock.unlock() }
        return headerReads
    }

    /// Every decode, in order: where from, and the size asked for.
    public var decodes: [(source: HostImageSource, maxPixelSize: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return decodeRequests
    }

    public func header(of source: HostImageSource) throws(DrawingError) -> HostImageHeader {
        lock.lock()
        headerReads.append(source)
        lock.unlock()
        return try Self.header(of: try bytes(of: source))
    }

    public func decode(_ source: HostImageSource, maxPixelSize: Int) throws(DrawingError) -> HostDecodedImage {
        lock.lock()
        decodeRequests.append((source, maxPixelSize))
        lock.unlock()
        let header = try Self.header(of: try bytes(of: source))
        let longer = header.longerSide
        let ratio = longer > maxPixelSize && maxPixelSize > 0 ? Double(maxPixelSize) / Double(longer) : 1
        return HostDecodedImage(
            pixelWidth: Swift.max(1, Int((Double(header.pixelWidth) * ratio).rounded())),
            pixelHeight: Swift.max(1, Int((Double(header.pixelHeight) * ratio).rounded())),
            image: Decode(source: source, maxPixelSize: maxPixelSize)
        )
    }

    public func image(pixels: [UInt8], width: Int, height: Int) throws(DrawingError) -> HostDecodedImage {
        lock.lock()
        decodeRequests.append((.data([]), Swift.max(width, height)))
        lock.unlock()
        return HostDecodedImage(pixelWidth: width, pixelHeight: height, image: Decode(source: .data([]), maxPixelSize: 0))
    }

    private func bytes(of source: HostImageSource) throws(DrawingError) -> [UInt8] {
        switch source {
        case .data(let data):
            return data
        case .file(let path):
            guard let data = FileManager.default.contents(atPath: path) else {
                throw .notFound
            }
            return [UInt8](data)
        }
    }

    /// The size a PNG's `IHDR` or a JPEG's start-of-frame says.
    public static func header(of bytes: [UInt8]) throws(DrawingError) -> HostImageHeader {
        if bytes.count >= 24, bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            let width = bigEndian(bytes, 16, 4)
            let height = bigEndian(bytes, 20, 4)
            guard width > 0, height > 0 else { throw .undecodable }
            return HostImageHeader(pixelWidth: width, pixelHeight: height)
        }
        if bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 {
            var index = 2
            while index + 9 < bytes.count {
                guard bytes[index] == 0xFF else { throw .undecodable }
                let marker = bytes[index + 1]
                let length = bigEndian(bytes, index + 2, 2)
                // Start of frame: every C0 to CF but the tables (C4, C8, CC).
                if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                    let height = bigEndian(bytes, index + 5, 2)
                    let width = bigEndian(bytes, index + 7, 2)
                    guard width > 0, height > 0 else { throw .undecodable }
                    return HostImageHeader(pixelWidth: width, pixelHeight: height)
                }
                index += 2 + length
            }
        }
        throw .undecodable
    }

    private static func bigEndian(_ bytes: [UInt8], _ start: Int, _ count: Int) -> Int {
        var value = 0
        for offset in 0..<count {
            value = value << 8 | Int(bytes[start + offset])
        }
        return value
    }
}
