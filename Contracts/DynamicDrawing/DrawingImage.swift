import DynamicRuntime

/// An image the host holds and decodes (`Documentation/Contracts/Drawing.md`).
/// App code makes one with `Image(contentsOf:)`, `Image(data:)` or
/// `Image(pixels:width:height:scale:)`, which wrap this contract.
///
/// No pixel crosses to the guest. The host reads the file, decodes it for
/// the size it's drawn at, and draws it where an `Image` node names its
/// `identifier()`. Making one reads nothing: the header is read when the
/// image is first shown or asked its size.
///
/// | Host | Decodes with |
/// |---|---|
/// | iOS / macOS | ImageIO |
/// | Android | `ImageDecoder`, or `BitmapFactory` below API 28 |
/// | Linux | gdk-pixbuf |
/// | Browser | `createImageBitmap` |
@DynamicRuntime("org.pureswift.drawing.Image")
public protocol DrawingImage: AnyObject {

    /// A file `Files` reaches: `directory` is a `FileDirectory`'s value,
    /// the app's own or a document's. Nothing is read yet. `maxPixelSize`
    /// caps the longer side of every decode; 0 doesn't.
    static func open(_ directory: Int32, path: String, maxPixelSize: Int32) -> Self

    /// Encoded bytes, in a format `formats()` names.
    static func decode(_ data: [UInt8], maxPixelSize: Int32) -> Self

    /// RGBA, 8 bits each, premultiplied, sRGB, rows from the top. Nil when
    /// the bytes don't match the size, or the host refuses the size.
    static func make(pixels: [UInt8], width: Int32, height: Int32, scale: Float) -> Self?

    /// The MIME types this host decodes.
    static func formats() -> [String]

    /// What an `Image` node's `image` prop names.
    func identifier() -> Int32

    /// Reads the header if it hasn't been, then `didMeasure` with the
    /// upright size in points and the scale, or `didFail`.
    func size(_ callback: DrawingCallback)
}

/// One operation's answer, from the host. Called once, on the main thread.
@DynamicCallback("org.pureswift.drawing.Callback")
public protocol DrawingCallback: AnyObject {

    /// Bytes read back: a bitmap's pixels or PNG, when bitmaps are built.
    func didRead(_ data: [UInt8])

    /// A size in points, and the scale that makes it pixels.
    func didMeasure(width: Float, height: Float, scale: Float)

    /// A `DrawingError` raw value, and what the host says of it.
    func didFail(_ code: Int32, message: String)
}
