import DynamicDrawing
import DynamicRuntime
import DynamicSwiftUI

/// The host's settings for drawing: what it draws with, and where it says
/// what went wrong. Main thread only.
///
/// ```swift
/// HostDrawing.backend = MyDrawingBackend()   // bitmaps, fonts, named colors
/// HostDrawing.canvasNeedsDisplay = { identifier in myViews[identifier]?.setNeedsDisplay() }
/// HostDrawingModule.register(in: runtime)
///
/// // A canvas view, when it draws:
/// HostCanvas.canvas(for: identifier)?.play(width: w, height: h, scale: s, into: renderer)
/// ```
public enum HostDrawing {

    /// Without one, bitmaps aren't made, and fonts measure nothing.
    nonisolated(unsafe) public static var backend: (any DrawingBackend)?

    /// Called when a canvas wants to be drawn again, with its identifier.
    nonisolated(unsafe) public static var canvasNeedsDisplay: (Int32) -> Void = { _ in }

    /// The most pixels on a side of a bitmap.
    nonisolated(unsafe) public static var maximumBitmapSide = 4096

    nonisolated(unsafe) public static var log: (String) -> Void = { print($0) }

    /// Forgets the settings, the canvases and the fonts, for tests.
    public static func reset() {
        backend = nil
        canvasNeedsDisplay = { _ in }
        maximumBitmapSide = 4096
        log = { print($0) }
        HostCanvas.reset()
        HostFont.reset()
    }
}

/// The `DrawingCanvas` contract: what a host's canvas view asks for its
/// drawing.
public final class HostCanvas: DrawingCanvas {

    nonisolated(unsafe) private static var canvases: [Int32: Weak] = [:]

    nonisolated(unsafe) private static var nextIdentifier: Int32 = 1

    private struct Weak {
        weak var canvas: HostCanvas?
    }

    let delegate: any DrawingCanvasDelegate

    let number: Int32

    /// Whether the guest asked to be drawn again since the last drawing.
    public private(set) var needsDisplay = true

    /// The last drawing, for drawing again without asking: when only the
    /// appearance changed.
    public private(set) var lastDrawing: [UInt8]?

    init(delegate: any DrawingCanvasDelegate) {
        self.delegate = delegate
        self.number = Self.nextIdentifier
        Self.nextIdentifier += 1
        Self.canvases[number] = Weak(canvas: self)
    }

    deinit {
        Self.canvases[number] = nil
    }

    public static func make(_ delegate: any DrawingCanvasDelegate) -> HostCanvas {
        HostCanvas(delegate: delegate)
    }

    public func identifier() -> Int32 {
        number
    }

    public func setNeedsDisplay() {
        needsDisplay = true
        HostDrawing.canvasNeedsDisplay(number)
    }

    /// The canvas a `Canvas` node names, while the guest holds it.
    public static func canvas(for identifier: Int32) -> HostCanvas? {
        canvases[identifier]?.canvas
    }

    /// Asks the guest for the drawing at a size, in points, and scale.
    public func drawing(width: Double, height: Double, scale: Double) -> [UInt8] {
        let drawing = delegate.draw(self, width: Float(width), height: Float(height), scale: Float(scale))
        needsDisplay = false
        lastDrawing = drawing
        return drawing
    }

    /// Asks for the drawing and replays it. The renderer's transform should
    /// already map points to the view's pixels.
    @discardableResult
    public func play(width: Double, height: Double, scale: Double, dark: Bool = false, into renderer: any DrawingRenderer) -> DrawingPlayer.Failure? {
        DrawingPlayer(dark: dark).play(drawing(width: width, height: height, scale: scale), into: renderer)
    }

    static func reset() {
        canvases = [:]
    }
}

/// The `DrawingBitmap` contract, over the backend's targets. Its drawings
/// carry on from one another: the state one leaves is the next one's.
public final class HostBitmap: DrawingBitmap {

    let target: any DrawingBitmapTarget

    let scale: Double

    public let pixelWidth: Int

    public let pixelHeight: Int

    private let player = DrawingPlayer()

    init(target: any DrawingBitmapTarget, pixelWidth: Int, pixelHeight: Int, scale: Double) {
        self.target = target
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        // Drawings are in points.
        target.renderer.concatenate(AffineTransform(scaleX: scale, y: scale))
    }

    public static func make(width: Float, height: Float, scale: Float, opaque: Bool) -> HostBitmap? {
        func pixels(_ value: Double) -> Int {
            let whole = Int(value)
            return Double(whole) < value ? whole + 1 : whole
        }
        guard width > 0, height > 0, scale > 0, width.isFinite, height.isFinite, scale.isFinite else { return nil }
        let pixelWidth = pixels(Double(width) * Double(scale))
        let pixelHeight = pixels(Double(height) * Double(scale))
        guard pixelWidth <= HostDrawing.maximumBitmapSide, pixelHeight <= HostDrawing.maximumBitmapSide,
              let target = HostDrawing.backend?.makeBitmap(pixelWidth: pixelWidth, pixelHeight: pixelHeight, opaque: opaque) else {
            return nil
        }
        return HostBitmap(target: target, pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: Double(scale))
    }

    public func draw(_ drawing: [UInt8]) {
        player.play(drawing, into: target.renderer)
    }

    /// Its pixels now, as an image of its own.
    public func image() -> any DrawingImage {
        if let image = HostImage.make(pixels: target.pixels(), width: Int32(pixelWidth), height: Int32(pixelHeight), scale: Float(scale)) {
            return image
        }
        // Pixels the image store refuses: an empty one, which draws nothing.
        return HostImage.make(pixels: [0, 0, 0, 0], width: 1, height: 1, scale: 1)!
    }

    public func pixels(_ callback: any DrawingCallback) {
        callback.didRead(target.pixels())
    }

    public func png(_ callback: any DrawingCallback) {
        guard let png = target.png() else {
            callback.didFail(DrawingError.unavailable.rawValue, message: "this host can't encode a PNG")
            return
        }
        callback.didRead(png)
    }
}

/// The `DrawingFont` contract, over the backend's fonts. Kept while the
/// guest holds it; a drawing names it by identifier.
public final class HostFont: DrawingFont {

    nonisolated(unsafe) private static var fonts: [Int32: Weak] = [:]

    nonisolated(unsafe) private static var nextIdentifier: Int32 = 1

    private struct Weak {
        weak var font: HostFont?
    }

    public let description: DrawingFontDescription

    /// The platform's font; `nil` without a backend.
    public let handle: (any DrawingFontHandle)?

    let number: Int32

    init(description: DrawingFontDescription) {
        self.description = description
        self.handle = HostDrawing.backend?.makeFont(description)
        self.number = Self.nextIdentifier
        Self.nextIdentifier += 1
        Self.fonts[number] = Weak(font: self)
    }

    deinit {
        Self.fonts[number] = nil
    }

    static let styles = ["largeTitle", "title", "title2", "title3", "headline", "subheadline", "body", "callout", "footnote", "caption", "caption2"]

    static let weights: [Font.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]

    static let designs: [Font.Design] = [.default, .serif, .rounded, .monospaced]

    public static func make(name: String?, size: Float, style: Int32, weight: Int32, design: Int32, italic: Bool) -> HostFont {
        let textStyle = style >= 1 && Int(style) <= styles.count ? styles[Int(style) - 1] : nil
        let description = DrawingFontDescription(
            name: name,
            size: Double(Swift.max(size, 0)),
            textStyle: textStyle,
            weight: weight >= 0 && Int(weight) < weights.count ? weights[Int(weight)] : .regular,
            design: design >= 0 && Int(design) < designs.count ? designs[Int(design)] : .default,
            italic: italic
        )
        return HostFont(description: description)
    }

    public func identifier() -> Int32 {
        number
    }

    public func metrics() -> [UInt8] {
        let m = handle?.metrics ?? FontMetrics(ascent: 0, descent: 0, leading: 0, capHeight: 0, xHeight: 0)
        return Self.floats([m.ascent, m.descent, m.leading, m.capHeight, m.xHeight])
    }

    public func measure(_ text: String, maxWidth: Float) -> [UInt8] {
        let size = handle?.measure(text, maxWidth: maxWidth > 0 ? Double(maxWidth) : nil) ?? .zero
        return Self.floats([size.width, size.height])
    }

    /// The font a drawing names, while the guest holds it.
    public static func font(_ identifier: Int32) -> HostFont? {
        fonts[identifier]?.font
    }

    static func floats(_ values: [Double]) -> [UInt8] {
        values.flatMap { value -> [UInt8] in
            let bits = Float(value).bitPattern
            return [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8(bits >> 24)]
        }
    }

    static func reset() {
        fonts = [:]
    }
}
