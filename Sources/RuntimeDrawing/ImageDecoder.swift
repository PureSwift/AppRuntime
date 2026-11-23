import DynamicDrawing

/// Where an image's bytes are, as a decoder reads them.
public enum HostImageSource: Sendable, Equatable {

    /// An absolute path, from `HostFiles`, or what `HostImages.findFile`
    /// gave on a host whose files aren't all paths.
    case file(String)

    /// Encoded bytes the guest sent.
    case data([UInt8])
}

/// What an image's header says: its upright size in pixels.
public struct HostImageHeader: Equatable, Sendable {

    public var pixelWidth: Int

    public var pixelHeight: Int

    public init(pixelWidth: Int, pixelHeight: Int) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// The longer side.
    public var longerSide: Int {
        Swift.max(pixelWidth, pixelHeight)
    }
}

/// A decode: its size in pixels, and the decoder's own image, which the
/// renderer draws: a `CGImage`, an `android.graphics.Bitmap`, a
/// `GdkTexture`.
public struct HostDecodedImage: @unchecked Sendable {

    public var pixelWidth: Int

    public var pixelHeight: Int

    public var image: AnyObject

    public init(pixelWidth: Int, pixelHeight: Int, image: AnyObject) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.image = image
    }

    /// The longer side.
    public var longerSide: Int {
        Swift.max(pixelWidth, pixelHeight)
    }
}

/// The platform's decoder: ImageIO, `ImageDecoder`, gdk-pixbuf. Called off
/// the main thread, one call at a time.
public protocol ImageDecoder: AnyObject, Sendable {

    /// The MIME types it decodes.
    var formats: [String] { get }

    /// The upright size in pixels, from the header alone.
    func header(of source: HostImageSource) throws(DrawingError) -> HostImageHeader

    /// Upright, with the longer side no more than `maxPixelSize`.
    func decode(_ source: HostImageSource, maxPixelSize: Int) throws(DrawingError) -> HostDecodedImage

    /// The platform's image of pixels the guest made: RGBA, 8 bits each,
    /// premultiplied, rows from the top.
    func image(pixels: [UInt8], width: Int, height: Int) throws(DrawingError) -> HostDecodedImage
}
