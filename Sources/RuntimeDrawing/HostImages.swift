import Dispatch
import DynamicDrawing
import DynamicFiles
import DynamicRuntime
import RuntimeHost

/// The image half of `RuntimeDrawing` (`Documentation/Contracts/Drawing.md`):
/// the `DrawingImage` contract over a host's `ImageDecoder`, and what a
/// renderer asks it for when an `Image` node names an image.
///
/// ```swift
/// HostImages.decoder = PlatformImageDecoder()
/// HostDrawingModule.register(in: runtime)
///
/// // In the renderer, for an Image node's `image` prop:
/// let image = HostImages.image(identifier)
/// image?.header { header in … }                        // for layout
/// image?.decoded(forPixelSize: 1800) { decoded in … }  // at once when what it holds is enough
/// ```
///
/// Everything here is called on the main thread, and answers on it. The
/// decoder is called off it, through `work`.
public enum HostImages {

    /// The platform's decoder. Without one, images can be made, `formats()`
    /// is empty, and every size and decode fails with `unavailable`.
    nonisolated(unsafe) public static var decoder: (any ImageDecoder)?

    /// Where a file `Files` names is, as the decoder reads it. It fails as
    /// `Files` would. The default is `HostFiles`' path, checked to be a
    /// file.
    nonisolated(unsafe) public static var findFile: (Int32, String) throws(FileError) -> String = findPath

    /// The most pixels on a side this host decodes or takes from the guest.
    nonisolated(unsafe) public static var maximumSide = 16384

    /// Runs the decoder's work off the main thread. The default is a serial
    /// queue; whatever replaces it must keep the order.
    nonisolated(unsafe) public static var work: @Sendable (@escaping @Sendable () -> Void) -> Void = defaultWork

    /// Runs an answer on the main thread. The default is the main dispatch
    /// queue; a host with a loop of its own posts to that.
    nonisolated(unsafe) public static var deliver: @Sendable (@escaping @Sendable () -> Void) -> Void = defaultDeliver

    /// Where an image that can't be read is said, once for each image.
    nonisolated(unsafe) public static var log: (String) -> Void = { print($0) }

    private static let queue = DispatchQueue(label: "org.pureswift.runtime.drawing")

    private static let defaultWork: @Sendable (@escaping @Sendable () -> Void) -> Void = { queue.async(execute: $0) }

    private static let defaultDeliver: @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    /// `HostFiles`' path of a file, checked to be one.
    public static func findPath(_ directory: Int32, _ path: String) throws(FileError) -> String {
        let found = try HostFiles.path(of: directory, path: path)
        guard HostFiles.kind(ofItemAt: found) == .file else {
            throw .notFound
        }
        return found
    }

    // MARK: Images

    private struct Weak {
        weak var image: HostImage?
    }

    nonisolated(unsafe) private static var images: [Int32: Weak] = [:]

    nonisolated(unsafe) private static var nextIdentifier: Int32 = 1

    static func add(_ image: HostImage) -> Int32 {
        let number = nextIdentifier
        nextIdentifier = nextIdentifier == Int32.max ? 1 : nextIdentifier + 1
        images[number] = Weak(image: image)
        return number
    }

    static func remove(_ number: Int32) {
        images[number] = nil
    }

    /// The image an `Image` node's `image` prop names, while the guest
    /// holds it.
    public static func image(_ identifier: Int32) -> HostImage? {
        images[identifier]?.image
    }

    /// The images the guest holds.
    public static var live: [HostImage] {
        images.values.compactMap { $0.image }
    }

    /// For the platform's memory warning: drops every decode that nothing
    /// asked for since the trim before. A renderer that draws an image
    /// again asks for it, and it's decoded again.
    public static func trim() {
        for image in live {
            image.trim()
        }
    }

    /// The size to decode for `pixelSize` on the longer side: the power of
    /// two at or above it, so a resize by a few points doesn't decode
    /// again, and never more than the image has, its `maxPixelSize`, or
    /// `maximumSide`.
    public static func decodeSize(forPixelSize pixelSize: Int, longerSide: Int, maxPixelSize: Int) -> Int {
        let wanted = Swift.max(1, pixelSize)
        var size = 1
        while size < wanted, size < 1 << 30 {
            size <<= 1
        }
        var cap = Swift.min(longerSide, maximumSide)
        if maxPixelSize > 0 {
            cap = Swift.min(cap, maxPixelSize)
        }
        return Swift.max(1, Swift.min(size, cap))
    }

    /// Forgets the decoder and the settings, for tests and for a host that
    /// starts the guest again. Images the guest holds stay.
    public static func reset() {
        decoder = nil
        findFile = findPath
        maximumSide = 16384
        work = defaultWork
        deliver = defaultDeliver
        log = { print($0) }
    }
}

/// One image the guest holds. Its release is the guest letting go: the
/// decode goes, and an `Image` node that still names it draws nothing.
public final class HostImage: DrawingImage {

    enum Source {
        case file(directory: Int32, path: String)
        case data([UInt8])
        case pixels([UInt8], width: Int, height: Int)
    }

    private enum HeaderState {
        case unread
        case reading([(Result<HostImageHeader, DrawingError>) -> Void])
        case read(Result<HostImageHeader, DrawingError>)
    }

    let source: Source

    /// The cap on the longer side of every decode; 0 is none.
    public let maxPixelSize: Int

    /// Pixels per point: 1 for a file or bytes.
    public let scale: Double

    private var number: Int32 = 0

    private var headerState = HeaderState.unread

    /// The largest decode asked for and finished, which a renderer shows
    /// scaled while a sharper one is decoded.
    public private(set) var decodedImage: HostDecodedImage?

    /// The size `decodedImage` was decoded for.
    private var decodedSize = 0

    /// The size being decoded.
    private var decoding: Int?

    private var waiting: [(size: Int, completion: (Result<HostDecodedImage, DrawingError>) -> Void)] = []

    /// Whether something asked for the decode since the last trim.
    private var used = false

    private var hasLogged = false

    init(_ source: Source, maxPixelSize: Int, scale: Double) {
        self.source = source
        self.maxPixelSize = maxPixelSize
        self.scale = scale
        if case .pixels(_, let width, let height) = source {
            headerState = .read(.success(HostImageHeader(pixelWidth: width, pixelHeight: height)))
        }
        self.number = HostImages.add(self)
    }

    deinit {
        HostImages.remove(number)
    }

    // MARK: The contract

    public static func open(_ directory: Int32, path: String, maxPixelSize: Int32) -> HostImage {
        HostImage(.file(directory: directory, path: path), maxPixelSize: Int(Swift.max(0, maxPixelSize)), scale: 1)
    }

    public static func decode(_ data: [UInt8], maxPixelSize: Int32) -> HostImage {
        HostImage(.data(data), maxPixelSize: Int(Swift.max(0, maxPixelSize)), scale: 1)
    }

    public static func make(pixels: [UInt8], width: Int32, height: Int32, scale: Float) -> HostImage? {
        let width = Int(width)
        let height = Int(height)
        guard width > 0, height > 0, scale > 0,
              width <= HostImages.maximumSide, height <= HostImages.maximumSide,
              pixels.count == width * height * 4 else {
            return nil
        }
        return HostImage(.pixels(pixels, width: width, height: height), maxPixelSize: 0, scale: Double(scale))
    }

    public static func formats() -> [String] {
        HostImages.decoder?.formats ?? []
    }

    public func identifier() -> Int32 {
        number
    }

    public func size(_ callback: any DrawingCallback) {
        let held = MainThreadHeld(callback)
        let scale = self.scale
        header { result in
            HostImages.deliver {
                guard let callback = held.take() else { return }
                switch result {
                case .success(let header):
                    callback.didMeasure(
                        width: Float(Double(header.pixelWidth) / scale),
                        height: Float(Double(header.pixelHeight) / scale),
                        scale: Float(scale)
                    )
                case .failure(let error):
                    callback.didFail(error.rawValue, message: Self.describe(error))
                }
            }
        }
    }

    // MARK: For the renderer

    /// The header: read once, and every answer after is from it. At once
    /// when it's been read.
    public func header(_ completion: @escaping (Result<HostImageHeader, DrawingError>) -> Void) {
        switch headerState {
        case .read(let result):
            completion(result)
        case .reading(var waiting):
            waiting.append(completion)
            headerState = .reading(waiting)
        case .unread:
            headerState = .reading([completion])
            readHeader()
        }
    }

    /// A decode good for `pixelSize` on the longer side, where it's drawn:
    /// at once when what it holds is enough, otherwise after one decode.
    /// One decode runs at a time; a request that arrives meanwhile waits
    /// for it, or for the next, which is for the largest still waiting.
    public func decoded(forPixelSize pixelSize: Int, _ completion: @escaping (Result<HostDecodedImage, DrawingError>) -> Void) {
        used = true
        header { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let header):
                let size = HostImages.decodeSize(forPixelSize: pixelSize, longerSide: header.longerSide, maxPixelSize: self.maxPixelSize)
                if let decodedImage = self.decodedImage, self.decodedSize >= size {
                    completion(.success(decodedImage))
                    return
                }
                self.waiting.append((size, completion))
                self.startDecode()
            }
        }
    }

    func trim() {
        if !used, decoding == nil {
            decodedImage = nil
            decodedSize = 0
        }
        used = false
    }

    // MARK: Reading

    /// Where the decoder reads, found through `HostFiles` each time, so a
    /// document the app let go of fails with `notPermitted`.
    private func resolve() throws(DrawingError) -> HostImageSource {
        switch source {
        case .file(let directory, let path):
            do throws(FileError) {
                return .file(try HostImages.findFile(directory, path))
            } catch {
                throw error == .notPermitted ? .notPermitted : .notFound
            }
        case .data(let data):
            return .data(data)
        case .pixels:
            return .data([])
        }
    }

    private func readHeader() {
        guard let decoder = HostImages.decoder else {
            finishHeader(.failure(.unavailable))
            return
        }
        let found: HostImageSource
        do throws(DrawingError) {
            found = try resolve()
        } catch {
            finishHeader(.failure(error))
            return
        }
        let number = self.number
        let deliver = HostImages.deliver
        HostImages.work {
            let result: Result<HostImageHeader, DrawingError>
            do throws(DrawingError) {
                result = .success(try decoder.header(of: found))
            } catch {
                result = .failure(error)
            }
            deliver {
                HostImages.image(number)?.finishHeader(result)
            }
        }
    }

    private func finishHeader(_ result: Result<HostImageHeader, DrawingError>) {
        // A header that couldn't be read for want of access is read again
        // next time: the app may be given the file again.
        let waiting: [(Result<HostImageHeader, DrawingError>) -> Void]
        if case .reading(let list) = headerState {
            waiting = list
        } else {
            waiting = []
        }
        if case .failure(let error) = result, error == .notPermitted || error == .unavailable {
            headerState = .unread
        } else {
            headerState = .read(result)
        }
        if case .failure(let error) = result {
            report(error)
        }
        for completion in waiting {
            completion(result)
        }
    }

    private func startDecode() {
        guard decoding == nil, let size = waiting.map({ $0.size }).max() else { return }
        guard let decoder = HostImages.decoder else {
            finishDecode(size, .failure(.unavailable))
            return
        }
        let found: HostImageSource
        do throws(DrawingError) {
            found = try resolve()
        } catch {
            finishDecode(size, .failure(error))
            return
        }
        decoding = size
        let pixels: (bytes: [UInt8], width: Int, height: Int)?
        if case .pixels(let bytes, let width, let height) = source {
            pixels = (bytes, width, height)
        } else {
            pixels = nil
        }
        let number = self.number
        let deliver = HostImages.deliver
        HostImages.work {
            let result: Result<HostDecodedImage, DrawingError>
            do throws(DrawingError) {
                if let pixels {
                    result = .success(try decoder.image(pixels: pixels.bytes, width: pixels.width, height: pixels.height))
                } else {
                    result = .success(try decoder.decode(found, maxPixelSize: size))
                }
            } catch {
                result = .failure(error)
            }
            deliver {
                HostImages.image(number)?.finishDecode(size, result)
            }
        }
    }

    private func finishDecode(_ size: Int, _ result: Result<HostDecodedImage, DrawingError>) {
        decoding = nil
        switch result {
        case .success(let decoded):
            if size >= decodedSize {
                decodedImage = decoded
                decodedSize = size
            }
            let ready = waiting.filter { $0.size <= decodedSize }
            waiting.removeAll { $0.size <= decodedSize }
            for request in ready {
                request.completion(.success(decoded))
            }
            startDecode()
        case .failure(let error):
            report(error)
            let failed = waiting
            waiting = []
            for request in failed {
                request.completion(.failure(error))
            }
        }
    }

    private func report(_ error: DrawingError) {
        guard !hasLogged else { return }
        hasLogged = true
        HostImages.log("image \(number) can't be drawn: \(Self.describe(error))")
    }

    static func describe(_ error: DrawingError) -> String {
        switch error {
        case .unknown: return "unknown error"
        case .cancelled: return "cancelled"
        case .notFound: return "no such file"
        case .undecodable: return "not an image this host decodes"
        case .tooLarge: return "too many pixels"
        case .unavailable: return "this host decodes no images"
        case .notPermitted: return "the app may not read the file"
        }
    }
}

/// The drawing module: registers `HostImage` for `DrawingImage`, and the
/// callback interface. The canvas, bitmaps and fonts come later.
public enum HostDrawingModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [DrawingImageProxy.descriptor, DrawingCallbackProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        DrawingImageProxy.register(HostImage.self, in: registrar)
        DrawingCallbackProxy.registerInterface(in: registrar)
    }
}
