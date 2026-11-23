import DynamicDrawing
import DynamicSwiftUI

/// A color as a renderer takes it: sRGB, 0 to 1, not premultiplied. A named
/// one is resolved by the backend for the appearance being drawn.
public struct DrawingColor: Equatable, Sendable {

    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = DrawingColor(red: 0, green: 0, blue: 0)
    public static let clear = DrawingColor(red: 0, green: 0, blue: 0, alpha: 0)
}

public struct DrawingShadow: Equatable, Sendable {
    public var offset: Size
    public var blur: Double
    public var color: DrawingColor

    public init(offset: Size, blur: Double, color: DrawingColor) {
        self.offset = offset
        self.blur = blur
        self.color = color
    }
}

/// A gradient with its colors resolved.
public struct DrawingGradient: Equatable, Sendable {

    public struct Stop: Equatable, Sendable {
        public var location: Double
        public var color: DrawingColor

        public init(location: Double, color: DrawingColor) {
            self.location = location
            self.color = color
        }
    }

    public var stops: [Stop]

    public init(stops: [Stop]) {
        self.stops = stops
    }
}

/// What a drawing is replayed into: a view's context, or a bitmap's.
/// CoreGraphics' operations, with the origin at the top left and y down, in
/// points; whatever draws a view applies its scale before it plays. A host
/// adapts it to the context it draws with: a Silica `CGContext`, a Cairo
/// context, an Android `Canvas`.
///
/// Paths arrive in user space: the renderer's transform, as `concatenate`
/// set it, puts them on the canvas, and a stroke's width is in user space
/// too, as in CoreGraphics.
public protocol DrawingRenderer: AnyObject {

    func save()
    func restore()
    func concatenate(_ transform: AffineTransform)

    func setAlpha(_ alpha: Double)
    func setBlendMode(_ mode: BlendMode)
    func setAntialias(_ antialias: Bool)
    func setFillColor(_ color: DrawingColor)
    func setStrokeColor(_ color: DrawingColor)
    func setStrokeStyle(_ style: StrokeStyle)
    /// `nil` removes it.
    func setShadow(_ shadow: DrawingShadow?)

    func fill(_ path: Path, rule: FillRule)
    func stroke(_ path: Path)
    func clip(_ path: Path, rule: FillRule)
    func clear(_ rect: Rect)

    /// Fills `rect`, upright. Ask the image for the pixels the rect covers
    /// with `decoded(forPixelSize:)`.
    func draw(_ image: HostImage, in rect: Rect)

    /// One line, with `anchor` of its bounds at `point`.
    func draw(_ text: String, font: any DrawingFontHandle, at point: Point, anchor: UnitPoint)

    /// Wrapped to the rect's width, from its top, cut at its bottom.
    func draw(_ text: String, font: any DrawingFontHandle, in rect: Rect, alignment: TextAlignment)

    func drawLinearGradient(_ gradient: DrawingGradient, start: Point, end: Point, options: GradientOptions)
    func drawRadialGradient(_ gradient: DrawingGradient, startCenter: Point, startRadius: Double, endCenter: Point, endRadius: Double, options: GradientOptions)

    /// What's drawn until `endLayer` is composited as one.
    func beginLayer()
    func endLayer()
}

/// What a host supplies to draw: bitmaps, fonts, and named colors.
/// Everything is called on the main thread.
public protocol DrawingBackend: AnyObject {

    /// A render target off screen, `pixelWidth` by `pixelHeight`, clear or
    /// black when `opaque`; `nil` for a size it refuses.
    func makeBitmap(pixelWidth: Int, pixelHeight: Int, opaque: Bool) -> (any DrawingBitmapTarget)?

    /// The platform's font for a description.
    func makeFont(_ description: DrawingFontDescription) -> any DrawingFontHandle

    /// A named color, as the frontend names them (`primary`, `accentColor`,
    /// `red`…), for the light or the dark appearance; `nil` for a name it
    /// doesn't know, which draws black.
    func color(named name: String, dark: Bool) -> DrawingColor?
}

/// A bitmap's pixels in the host.
public protocol DrawingBitmapTarget: AnyObject {

    /// What draws into it. Its state carries from one drawing to the next.
    var renderer: any DrawingRenderer { get }

    /// RGBA, 8 bits each, premultiplied, sRGB, rows from the top.
    func pixels() -> [UInt8]

    /// A PNG of it; `nil` where the host can't encode one.
    func png() -> [UInt8]?
}

/// A font as the guest describes it.
public struct DrawingFontDescription: Equatable, Sendable {

    /// A font's name; `nil` for the system's.
    public var name: String?

    /// Points; 0 with a text style.
    public var size: Double

    /// `largeTitle`…`caption2`, which the platform sizes; `nil` for a size.
    public var textStyle: String?

    public var weight: Font.Weight

    public var design: Font.Design

    public var italic: Bool

    public init(name: String? = nil, size: Double, textStyle: String? = nil, weight: Font.Weight = .regular, design: Font.Design = .default, italic: Bool = false) {
        self.name = name
        self.size = size
        self.textStyle = textStyle
        self.weight = weight
        self.design = design
        self.italic = italic
    }
}

/// A platform font, which lays out and measures text the way it's drawn.
public protocol DrawingFontHandle: AnyObject {

    var metrics: FontMetrics { get }

    /// What `text` occupies: one line, or wrapped at `maxWidth`.
    func measure(_ text: String, maxWidth: Double?) -> Size
}
