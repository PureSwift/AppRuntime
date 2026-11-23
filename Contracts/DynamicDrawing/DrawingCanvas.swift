import DynamicRuntime

/// A view the guest draws (`Documentation/Contracts/Drawing.md`). A
/// `Canvas` node carries its `identifier()`; the host asks the delegate for
/// a drawing when it has a size for it, and again after `setNeedsDisplay()`
/// or when the size, the scale or the user's text size changes. App code
/// uses `Canvas`, which wraps this contract.
///
/// It needs no capability.
@DynamicRuntime("org.pureswift.drawing.Canvas")
public protocol DrawingCanvas: AnyObject {

    static func make(_ delegate: DrawingCanvasDelegate) -> Self

    /// What a `Canvas` node's `canvas` prop names.
    func identifier() -> Int32

    /// The host asks for the drawing again before its next frame.
    func setNeedsDisplay()
}

/// Draws a canvas, when its host asks. Called on the main thread.
@DynamicCallback("org.pureswift.drawing.CanvasDelegate")
public protocol DrawingCanvasDelegate: AnyObject {

    /// The drawing, as `GraphicsContext` records it, for a canvas `width` by
    /// `height` points at `scale` pixels a point.
    func draw(_ canvas: DrawingCanvas, width: Float, height: Float, scale: Float) -> [UInt8]
}

/// Pixels the guest draws into, off screen. App code uses `BitmapContext`.
@DynamicRuntime("org.pureswift.drawing.Bitmap")
public protocol DrawingBitmap: AnyObject {

    /// `width` and `height` in points; its pixels are those times `scale`,
    /// rounded up. Nil when the host refuses the size: every host takes
    /// 4096 pixels on a side.
    static func make(width: Float, height: Float, scale: Float, opaque: Bool) -> Self?

    /// Replays a drawing over what's there.
    func draw(_ drawing: [UInt8])

    /// What's there now, as an image that won't change.
    func image() -> DrawingImage

    /// RGBA, 8 bits each, premultiplied, sRGB, rows from the top, through
    /// `didRead`.
    func pixels(_ callback: DrawingCallback)

    /// A PNG of it, through `didRead`.
    func png(_ callback: DrawingCallback)
}

/// A font at a size, for drawing and measuring text. App code uses the
/// frontend's `Font`, which `GraphicsContext` and `Font.measure` turn into
/// one of these.
@DynamicRuntime("org.pureswift.drawing.Font")
public protocol DrawingFont: AnyObject {

    /// `name` is a font's name, or nil for the system's. `style` is a text
    /// style, 1 `largeTitle` to 11 `caption2` in the frontend's order, or 0
    /// for `size` in points. `weight` is 0 `ultraLight` to 8 `black`, 3
    /// regular; `design` 0 default, 1 serif, 2 rounded, 3 monospaced.
    static func make(name: String?, size: Float, style: Int32, weight: Int32, design: Int32, italic: Bool) -> Self

    /// What a drawing's font command names.
    func identifier() -> Int32

    /// Ascent, descent, leading, cap height and x height, in points: five
    /// 32-bit floats, little-endian.
    func metrics() -> [UInt8]

    /// Width and height `text` occupies when drawn, wrapped at `maxWidth`
    /// when it's over 0: two 32-bit floats.
    func measure(_ text: String, maxWidth: Float) -> [UInt8]
}
