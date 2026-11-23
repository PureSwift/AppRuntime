import DynamicDrawing
import DynamicSwiftUI

/// A renderer that writes down each call, one line each, for tests: a host's
/// and this package's.
///
/// Numbers are written as they are, so a test can compare them exactly
/// where they're whole, and paths as `M x y`, `L x y`, `Q cx cy x y`,
/// `C c1x c1y c2x c2y x y` and `Z`.
public final class RecordingRenderer: DrawingRenderer {

    public private(set) var calls: [String] = []

    public init() { }

    public func removeAll() {
        calls = []
    }

    public func save() { calls.append("save") }
    public func restore() { calls.append("restore") }

    public func concatenate(_ t: AffineTransform) {
        calls.append("concatenate \(Self.number(t.a)) \(Self.number(t.b)) \(Self.number(t.c)) \(Self.number(t.d)) \(Self.number(t.tx)) \(Self.number(t.ty))")
    }

    public func setAlpha(_ alpha: Double) { calls.append("alpha \(Self.number(alpha))") }
    public func setBlendMode(_ mode: BlendMode) { calls.append("blend \(mode)") }
    public func setAntialias(_ antialias: Bool) { calls.append("antialias \(antialias)") }
    public func setFillColor(_ color: DrawingColor) { calls.append("fill color \(Self.describe(color))") }
    public func setStrokeColor(_ color: DrawingColor) { calls.append("stroke color \(Self.describe(color))") }

    public func setStrokeStyle(_ style: StrokeStyle) {
        let dash = style.dash.map(Self.number).joined(separator: ",")
        calls.append("stroke style \(Self.number(style.lineWidth)) \(style.lineCap) \(style.lineJoin) \(Self.number(style.miterLimit)) [\(dash)] \(Self.number(style.dashPhase))")
    }

    public func setShadow(_ shadow: DrawingShadow?) {
        guard let shadow else {
            calls.append("no shadow")
            return
        }
        calls.append("shadow \(Self.number(shadow.offset.width)) \(Self.number(shadow.offset.height)) \(Self.number(shadow.blur)) \(Self.describe(shadow.color))")
    }

    public func fill(_ path: Path, rule: FillRule) { calls.append("fill \(rule) \(Self.describe(path))") }
    public func stroke(_ path: Path) { calls.append("stroke \(Self.describe(path))") }
    public func clip(_ path: Path, rule: FillRule) { calls.append("clip \(rule) \(Self.describe(path))") }
    public func clear(_ rect: Rect) { calls.append("clear \(Self.describe(rect))") }

    public func draw(_ image: HostImage, in rect: Rect) {
        calls.append("image \(image.identifier()) \(Self.describe(rect))")
    }

    public func draw(_ text: String, font: any DrawingFontHandle, at point: Point, anchor: UnitPoint) {
        calls.append("text \"\(text)\" at \(Self.number(point.x)) \(Self.number(point.y)) anchor \(Self.number(anchor.x)) \(Self.number(anchor.y))")
    }

    public func draw(_ text: String, font: any DrawingFontHandle, in rect: Rect, alignment: TextAlignment) {
        calls.append("text \"\(text)\" in \(Self.describe(rect)) \(alignment)")
    }

    public func drawLinearGradient(_ gradient: DrawingGradient, start: Point, end: Point, options: GradientOptions) {
        calls.append("linear \(Self.describe(gradient)) \(Self.number(start.x)) \(Self.number(start.y)) \(Self.number(end.x)) \(Self.number(end.y)) \(options.rawValue)")
    }

    public func drawRadialGradient(_ gradient: DrawingGradient, startCenter: Point, startRadius: Double, endCenter: Point, endRadius: Double, options: GradientOptions) {
        calls.append("radial \(Self.describe(gradient)) \(Self.number(startCenter.x)) \(Self.number(startCenter.y)) \(Self.number(startRadius)) \(Self.number(endCenter.x)) \(Self.number(endCenter.y)) \(Self.number(endRadius)) \(options.rawValue)")
    }

    public func beginLayer() { calls.append("begin layer") }
    public func endLayer() { calls.append("end layer") }

    // MARK: Describing

    /// Whole numbers without a fraction, others to three places.
    public static func number(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        if rounded == rounded.rounded() && Swift.abs(rounded) < 1e9 {
            return String(Int(rounded))
        }
        return String(rounded)
    }

    public static func describe(_ color: DrawingColor) -> String {
        "\(number(color.red)) \(number(color.green)) \(number(color.blue)) \(number(color.alpha))"
    }

    public static func describe(_ rect: Rect) -> String {
        "\(number(rect.minX)) \(number(rect.minY)) \(number(rect.width)) \(number(rect.height))"
    }

    public static func describe(_ gradient: DrawingGradient) -> String {
        gradient.stops.map { "\(number($0.location)):\(describe($0.color))" }.joined(separator: ",")
    }

    public static func describe(_ path: Path) -> String {
        path.elements.map { element -> String in
            switch element {
            case .move(let p): return "M \(number(p.x)) \(number(p.y))"
            case .line(let p): return "L \(number(p.x)) \(number(p.y))"
            case .quadCurve(let p, let c): return "Q \(number(c.x)) \(number(c.y)) \(number(p.x)) \(number(p.y))"
            case .curve(let p, let c1, let c2): return "C \(number(c1.x)) \(number(c1.y)) \(number(c2.x)) \(number(c2.y)) \(number(p.x)) \(number(p.y))"
            case .closeSubpath: return "Z"
            }
        }.joined(separator: " ")
    }
}

/// A backend kept in memory, for tests: bitmaps that record what they're
/// asked and have clear pixels, fonts whose every character is half its size
/// wide, and the frontend's named colors in light and dark.
public final class MemoryDrawingBackend: DrawingBackend {

    public final class Bitmap: DrawingBitmapTarget {
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let opaque: Bool
        public let recorder = RecordingRenderer()
        public var renderer: any DrawingRenderer { recorder }

        init(pixelWidth: Int, pixelHeight: Int, opaque: Bool) {
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.opaque = opaque
        }

        /// Clear, or opaque black; each pixel's first byte is the number of
        /// calls drawn so far, so a test can see a read came after them.
        public func pixels() -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
            for index in Swift.stride(from: 0, to: pixels.count, by: 4) {
                pixels[index] = UInt8(clamping: recorder.calls.count)
                if opaque { pixels[index + 3] = 255 }
            }
            return pixels
        }

        /// A PNG's signature, then the size: not a real PNG.
        public func png() -> [UInt8]? {
            [0x89, 0x50, 0x4E, 0x47, UInt8(clamping: pixelWidth), UInt8(clamping: pixelHeight)]
        }
    }

    public final class FontHandle: DrawingFontHandle {
        public let description: DrawingFontDescription
        let size: Double

        init(_ description: DrawingFontDescription) {
            self.description = description
            self.size = description.size > 0 ? description.size : 17
        }

        public var metrics: FontMetrics {
            FontMetrics(ascent: size * 0.8, descent: size * 0.2, leading: 0, capHeight: size * 0.7, xHeight: size * 0.5)
        }

        public func measure(_ text: String, maxWidth: Double?) -> Size {
            let width = Double(text.count) * size / 2
            guard let maxWidth, maxWidth > 0, width > maxWidth else {
                return Size(width: width, height: size)
            }
            var lines = Int(width / maxWidth)
            if Double(lines) * maxWidth < width { lines += 1 }
            return Size(width: maxWidth, height: Double(lines) * size)
        }
    }

    public private(set) var bitmaps: [Bitmap] = []

    public private(set) var fonts: [DrawingFontDescription] = []

    public init() { }

    public func makeBitmap(pixelWidth: Int, pixelHeight: Int, opaque: Bool) -> (any DrawingBitmapTarget)? {
        let bitmap = Bitmap(pixelWidth: pixelWidth, pixelHeight: pixelHeight, opaque: opaque)
        bitmaps.append(bitmap)
        return bitmap
    }

    public func makeFont(_ description: DrawingFontDescription) -> any DrawingFontHandle {
        fonts.append(description)
        return FontHandle(description)
    }

    public func color(named name: String, dark: Bool) -> DrawingColor? {
        switch name {
        case "primary": return dark ? DrawingColor(red: 1, green: 1, blue: 1) : .black
        case "secondary": return DrawingColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.6)
        case "accentColor", "blue": return DrawingColor(red: 0, green: 0.478, blue: 1)
        case "white": return DrawingColor(red: 1, green: 1, blue: 1)
        case "black": return .black
        case "clear": return .clear
        case "gray": return DrawingColor(red: 0.557, green: 0.557, blue: 0.576)
        case "red": return DrawingColor(red: 1, green: 0.231, blue: 0.188)
        case "orange": return DrawingColor(red: 1, green: 0.584, blue: 0)
        case "green": return DrawingColor(red: 0.204, green: 0.78, blue: 0.349)
        default: return nil
        }
    }
}
