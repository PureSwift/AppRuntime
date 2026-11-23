import DynamicFiles
import DynamicRuntime
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// Images the host decodes: from a file, from bytes, from pixels.
///
/// ```swift
/// ScrollView([.horizontal, .vertical]) {
///     Image(contentsOf: document.path)
///         .resizable()
///         .scaledToFit()
/// }
/// .zoomable(1...8)
///
/// let size = try await Image(contentsOf: document.path).size   // the header, not a decode
/// let thumbnail = Image(contentsOf: document.path, maximumPixelSize: 256)
/// ```
///
/// The host decodes an image for the pixels it covers where it's drawn,
/// and again, sharper, when it's shown larger. `maximumPixelSize` caps
/// the longer side of every decode, for a thumbnail that stays small. The
/// orientation a file records is applied. An image that can't be read
/// draws nothing, and its `size` throws.
///
/// Copies of an image share one host image, which goes when the last copy
/// does and no tree shows it.
extension Image {

    /// A file `Files` reaches: the app's own, or a document the user
    /// picked. It's read through the document's access, so hold the
    /// `Document` while the image is shown.
    public init(contentsOf file: FilePath, maximumPixelSize: Int? = nil) {
        self.init(host: DrawingImageProxy.open(
            file.directory.rawValue,
            path: file.path,
            maxPixelSize: Self.cap(maximumPixelSize)
        ))
    }

    /// Encoded bytes the app already has: a contact's photo, a song's
    /// artwork. They're copied to the host once. For a file, name it.
    public init(data: [UInt8], maximumPixelSize: Int? = nil) {
        self.init(host: DrawingImageProxy.decode(data, maxPixelSize: Self.cap(maximumPixelSize)))
    }

    /// RGBA, 8 bits each, premultiplied, sRGB, rows from the top: `width`
    /// by `height` pixels, which are `width / scale` points across. Nil
    /// when the bytes don't match the size, or the host refuses the size.
    public init?(pixels: [UInt8], width: Int, height: Int, scale: Double = 1) {
        guard width > 0, height > 0, scale > 0, pixels.count == width * height * 4,
              let image = DrawingImageProxy.make(
                pixels: pixels,
                width: Int32(clamping: width),
                height: Int32(clamping: height),
                scale: Float(scale)
              ) else {
            return nil
        }
        self.init(host: image)
    }

    private init(host image: DrawingImageProxy) {
        self.init(_hostImage: image.identifier(), owner: ImageOwner(image))
    }

    private static func cap(_ maximumPixelSize: Int?) -> Int32 {
        Int32(clamping: Swift.max(0, maximumPixelSize ?? 0))
    }

    /// The MIME types this host decodes, to filter a picker with: PNG and
    /// JPEG on every host, and what else its platform decodes.
    public static var decodableTypes: [String] {
        DrawingImageProxy.formats()
    }

    /// The upright size in points, from the image's header: nothing is
    /// decoded to answer. A file's or bytes' points are its pixels. A
    /// symbol or a bundle image has no size here, and fails with
    /// `unavailable`.
    public func size(completion: @escaping (Result<Size, DrawingError>) -> Void) {
        guard let owner = _hostImage else {
            completion(.failure(.unavailable))
            return
        }
        owner._measure { width, height, failure in
            if failure == 0 {
                completion(.success(Size(width: width, height: height)))
            } else {
                completion(.failure(DrawingError(rawValue: failure) ?? .unknown))
            }
        }
    }

#if !EMBEDDED_NO_CONCURRENCY
    /// The upright size in points, from the image's header.
    public var size: Size {
        get async throws(DrawingError) {
            try await withCallback { (callback: Callback<Size, DrawingError>) in
                size { callback.resume(with: $0) }
            } onCancel: { callback in
                callback.resume(throwing: .cancelled)
            }
        }
    }
#endif
}

/// The host's image, held by the `Image` values made from it. Embedded
/// Swift can't cast an object back to its class, so `Image` reaches it
/// through the frontend's protocol.
final class ImageOwner: _HostImageOwner {

    let image: DrawingImageProxy

    init(_ image: DrawingImageProxy) {
        self.image = image
    }

    func _measure(_ completion: @escaping (Double, Double, Int32) -> Void) {
        image.size(Measure { result in
            switch result {
            case .success(let size):
                completion(size.width, size.height, 0)
            case .failure(let error):
                completion(0, 0, error == .unknown ? -1 : error.rawValue)
            }
        })
    }
}

/// One `size` call's callback. The host holds it until it answers.
private final class Measure: DrawingCallback {

    private var completion: ((Result<Size, DrawingError>) -> Void)?

    init(_ completion: @escaping (Result<Size, DrawingError>) -> Void) {
        self.completion = completion
    }

    /// Only a host's first answer counts.
    private func answer(_ result: Result<Size, DrawingError>) {
        guard let completion else { return }
        self.completion = nil
        completion(result)
    }

    func didRead(_ data: [UInt8]) {
        answer(.failure(.unknown))
    }

    func didMeasure(width: Float, height: Float, scale: Float) {
        answer(.success(Size(width: Double(width), height: Double(height))))
    }

    func didFail(_ code: Int32, message: String) {
        answer(.failure(DrawingError(rawValue: code) ?? .unknown))
    }
}
