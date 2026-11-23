import DynamicRuntime
import DynamicUI
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// Where a drawing is made: CoreGraphics' `CGContext`, without the prefix,
/// with the origin at the top left and y going down, in points.
///
/// It records: each call appends to a drawing the host replays, in one call,
/// when the canvas asks or a bitmap is read. The current transform and path
/// are kept here, so asking for them never reaches the host.
///
/// ```swift
/// Canvas { context, size in
///     context.setStrokeColor(.accentColor)
///     context.setLineWidth(4)
///     context.addEllipse(in: Rect(size: size).insetBy(dx: 2, dy: 2))
///     context.strokePath()
/// }
/// ```
///
/// SwiftUI's own spellings are here too: `fill(_:with:)`,
/// `stroke(_:with:lineWidth:)`, `drawLayer`, `opacity`. This context is a
/// reference, not SwiftUI's value: scope a change with `saveGState()` or
/// `drawLayer`, not by copying it.
public class GraphicsContext {

    var writer = DrawingWriter()

    private struct State {
        var ctm = AffineTransform.identity
        var stroke = StrokeStyle()
        var alpha = 1.0
        var font: Font?
    }

    private var state = State()

    private var saved: [State] = []

    /// The current path, in the space of the canvas: transformed as it's
    /// built, as CoreGraphics does.
    private var devicePath = Path()

    /// Host objects a drawing names, kept while it can be replayed.
    private(set) var retained: [AnyObject] = []

    /// The font the host was last told, so text doesn't repeat it.
    private var writtenFont: Font?

    init() { }

    /// The drawing so far.
    var drawing: [UInt8] {
        writer.bytes
    }

    // MARK: State

    public func saveGState() {
        saved.append(state)
        writer.command(.save)
    }

    /// Ignored without a matching save.
    public func restoreGState() {
        guard let last = saved.popLast() else { return }
        state = last
        writer.command(.restore)
    }

    /// Draws what `content` draws with its own copy of the state: SwiftUI's
    /// `drawLayer`, as a saved state.
    public func drawLayer(_ content: (GraphicsContext) -> Void) {
        saveGState()
        content(self)
        restoreGState()
    }

    // MARK: Transform

    /// The current transform, from user space to the canvas's.
    public var ctm: AffineTransform {
        state.ctm
    }

    public func concatenate(_ transform: AffineTransform) {
        state.ctm = transform.concatenating(state.ctm)
        writer.command(.concatenate) { $0.transform(transform) }
    }

    public func translateBy(x: Double, y: Double) {
        concatenate(AffineTransform(translationX: x, y: y))
    }

    public func scaleBy(x: Double, y: Double) {
        concatenate(AffineTransform(scaleX: x, y: y))
    }

    /// Radians; with y down, a positive angle turns clockwise on screen.
    public func rotate(by angle: Double) {
        concatenate(AffineTransform(rotationAngle: angle))
    }

    // MARK: Paint state

    public func setFillColor(_ color: Color) {
        writer.command(.fillColor) { $0.color(color) }
    }

    public func setStrokeColor(_ color: Color) {
        writer.command(.strokeColor) { $0.color(color) }
    }

    /// 0 to 1, multiplied into everything drawn after.
    public func setAlpha(_ alpha: Double) {
        state.alpha = Swift.max(0, Swift.min(1, alpha))
        writer.command(.alpha) { $0.float(state.alpha) }
    }

    /// SwiftUI's spelling of `setAlpha`.
    public var opacity: Double {
        get { state.alpha }
        set { setAlpha(newValue) }
    }

    public func setBlendMode(_ mode: BlendMode) {
        writer.command(.blendMode) { $0.u8(mode.rawValue) }
    }

    public func setShouldAntialias(_ antialias: Bool) {
        writer.command(.antialias) { $0.u8(antialias ? 1 : 0) }
    }

    /// A shadow under what's drawn after; `color` `nil` removes it.
    public func setShadow(offset: Size, blur: Double, color: Color? = Color(white: 0, opacity: 1.0 / 3)) {
        guard let color else {
            writer.command(.shadow)
            return
        }
        writer.command(.shadow) { writer in
            writer.float(offset.width)
            writer.float(offset.height)
            writer.float(blur)
            writer.color(color)
        }
    }

    // MARK: Stroke state

    public var strokeStyle: StrokeStyle {
        state.stroke
    }

    public func setStrokeStyle(_ style: StrokeStyle) {
        state.stroke = style
        writer.command(.strokeStyle) { writer in
            writer.float(style.lineWidth)
            writer.u8(style.lineCap.rawValue)
            writer.u8(style.lineJoin.rawValue)
            writer.float(style.miterLimit)
            writer.float(style.dashPhase)
            writer.u16(UInt16(clamping: style.dash.count))
            for length in style.dash.prefix(Int(UInt16.max)) {
                writer.float(length)
            }
        }
    }

    public func setLineWidth(_ width: Double) {
        var style = state.stroke
        style.lineWidth = width
        setStrokeStyle(style)
    }

    public func setLineCap(_ cap: LineCap) {
        var style = state.stroke
        style.lineCap = cap
        setStrokeStyle(style)
    }

    public func setLineJoin(_ join: LineJoin) {
        var style = state.stroke
        style.lineJoin = join
        setStrokeStyle(style)
    }

    public func setMiterLimit(_ limit: Double) {
        var style = state.stroke
        style.miterLimit = limit
        setStrokeStyle(style)
    }

    /// On, off, on…, from `phase`; empty is solid.
    public func setLineDash(phase: Double, lengths: [Double]) {
        var style = state.stroke
        style.dashPhase = phase
        style.dash = lengths
        setStrokeStyle(style)
    }

    // MARK: Path

    /// Throws away the current path.
    public func beginPath() {
        devicePath = Path()
    }

    public func move(to point: Point) {
        devicePath.move(to: point.applying(state.ctm))
    }

    public func addLine(to point: Point) {
        devicePath.addLine(to: point.applying(state.ctm))
    }

    public func addLines(between points: [Point]) {
        devicePath.addLines(points.map { $0.applying(state.ctm) })
    }

    public func addQuadCurve(to point: Point, control: Point) {
        devicePath.addQuadCurve(to: point.applying(state.ctm), control: control.applying(state.ctm))
    }

    public func addCurve(to point: Point, control1: Point, control2: Point) {
        devicePath.addCurve(to: point.applying(state.ctm), control1: control1.applying(state.ctm), control2: control2.applying(state.ctm))
    }

    public func addArc(center: Point, radius: Double, startAngle: Double, endAngle: Double, clockwise: Bool) {
        devicePath.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: clockwise, transform: state.ctm)
    }

    public func addArc(tangent1End: Point, tangent2End: Point, radius: Double) {
        // In user space, where the corner is round.
        var path = userPath
        path.addArc(tangent1End: tangent1End, tangent2End: tangent2End, radius: radius)
        devicePath = path.applying(state.ctm)
    }

    public func addRect(_ rect: Rect) {
        devicePath.addPath(Path(rect), transform: state.ctm)
    }

    public func addRects(_ rects: [Rect]) {
        for rect in rects {
            addRect(rect)
        }
    }

    public func addEllipse(in rect: Rect) {
        devicePath.addPath(Path(ellipseIn: rect), transform: state.ctm)
    }

    public func addPath(_ path: Path) {
        devicePath.addPath(path, transform: state.ctm)
    }

    public func closePath() {
        devicePath.closeSubpath()
    }

    /// The current path, in user space.
    public var path: Path? {
        devicePath.isEmpty ? nil : userPath
    }

    public var isPathEmpty: Bool {
        devicePath.isEmpty
    }

    /// In user space; `nil` with no path.
    public var currentPoint: Point? {
        devicePath.currentPoint.map { $0.applying(state.ctm.inverted()) }
    }

    public var boundingBoxOfPath: Rect {
        userPath.boundingRect
    }

    private var userPath: Path {
        devicePath.applying(state.ctm.inverted())
    }

    /// Takes the current path for painting, in user space, where the host's
    /// transform puts it back.
    private func takePath() -> Path? {
        guard !devicePath.isEmpty else { return nil }
        let path = userPath
        devicePath = Path()
        return path
    }

    // MARK: Painting the path

    public func fillPath(using rule: FillRule = .winding) {
        guard let path = takePath() else { return }
        fill(path, rule: rule)
    }

    public func strokePath() {
        guard let path = takePath() else { return }
        stroke(path)
    }

    public func drawPath(using mode: DrawingMode) {
        guard let path = takePath() else { return }
        switch mode {
        case .fill: fill(path, rule: .winding)
        case .eoFill: fill(path, rule: .evenOdd)
        case .stroke: stroke(path)
        case .fillStroke: fill(path, rule: .winding); stroke(path)
        case .eoFillStroke: fill(path, rule: .evenOdd); stroke(path)
        }
    }

    /// Intersects the clip with the current path.
    public func clip(using rule: FillRule = .winding) {
        guard let path = takePath() else { return }
        clip(to: path, rule: rule)
    }

    public func clip(to rect: Rect) {
        clip(to: Path(rect), rule: .winding)
    }

    public func clip(to path: Path, rule: FillRule = .winding) {
        guard !path.isEmpty else { return }
        writer.command(.clip) { writer in
            writer.u8(rule.rawValue)
            writer.path(path)
        }
    }

    // MARK: Painting shapes

    /// A path, filled with the fill color. It doesn't touch the current
    /// path.
    public func fill(_ path: Path, rule: FillRule = .winding) {
        guard !path.isEmpty else { return }
        writer.command(.fill) { writer in
            writer.u8(rule.rawValue)
            writer.path(path)
        }
    }

    /// A path, stroked with the stroke color and style.
    public func stroke(_ path: Path) {
        guard !path.isEmpty else { return }
        writer.command(.stroke) { $0.path(path) }
    }

    public func fill(_ rect: Rect) {
        guard !rect.isEmpty else { return }
        fill(Path(rect))
    }

    public func fill(_ rects: [Rect]) {
        for rect in rects {
            fill(rect)
        }
    }

    public func stroke(_ rect: Rect) {
        guard !rect.isEmpty else { return }
        stroke(Path(rect))
    }

    public func stroke(_ rect: Rect, width: Double) {
        saveGState()
        setLineWidth(width)
        stroke(rect)
        restoreGState()
    }

    public func fillEllipse(in rect: Rect) {
        fill(Path(ellipseIn: rect))
    }

    public func strokeEllipse(in rect: Rect) {
        stroke(Path(ellipseIn: rect))
    }

    /// Makes `rect` transparent.
    public func clear(_ rect: Rect) {
        guard !rect.isEmpty else { return }
        writer.command(.clear) { $0.rect(rect) }
    }

    // MARK: SwiftUI's spellings

    /// SwiftUI's: a path filled with a color, leaving the fill color as it
    /// was.
    public func fill(_ path: Path, with color: Color, style rule: FillRule = .winding) {
        drawLayer { context in
            context.setFillColor(color)
            context.fill(path, rule: rule)
        }
    }

    public func stroke(_ path: Path, with color: Color, lineWidth: Double = 1) {
        stroke(path, with: color, style: StrokeStyle(lineWidth: lineWidth))
    }

    public func stroke(_ path: Path, with color: Color, style: StrokeStyle) {
        drawLayer { context in
            context.setStrokeColor(color)
            context.setStrokeStyle(style)
            context.stroke(path)
        }
    }

    // MARK: Gradients

    /// Clipped to the current clip; `start` and `end` in user space.
    public func drawLinearGradient(_ gradient: Gradient, start: Point, end: Point, options: GradientOptions = []) {
        guard !gradient.stops.isEmpty else { return }
        writer.command(.linearGradient) { writer in
            writer.gradient(gradient)
            writer.point(start)
            writer.point(end)
            writer.u8(options.rawValue)
        }
    }

    public func drawRadialGradient(_ gradient: Gradient, startCenter: Point, startRadius: Double, endCenter: Point, endRadius: Double, options: GradientOptions = []) {
        guard !gradient.stops.isEmpty else { return }
        writer.command(.radialGradient) { writer in
            writer.gradient(gradient)
            writer.point(startCenter)
            writer.float(startRadius)
            writer.point(endCenter)
            writer.float(endRadius)
            writer.u8(options.rawValue)
        }
    }

    // MARK: Layers

    /// What's drawn until `endTransparencyLayer` is composited as one, with
    /// the alpha, blend mode and shadow in effect now.
    public func beginTransparencyLayer() {
        saved.append(state)
        writer.command(.beginLayer)
    }

    public func endTransparencyLayer() {
        guard let last = saved.popLast() else { return }
        state = last
        writer.command(.endLayer)
    }

    // MARK: Images

    /// Fills `rect` with the image, upright, as SwiftUI draws it. An image
    /// made by `DynamicDrawing` (`Image(contentsOf:)`, `Image(data:)`, a
    /// bitmap's) draws; one by name or symbol draws nothing yet.
    public func draw(_ image: Image, in rect: Rect) {
        guard let identifier = image._hostImageIdentifier, let owner = image._hostImage, !rect.isEmpty else { return }
        retain(owner)
        writer.command(.image) { writer in
            writer.u32(UInt32(bitPattern: identifier))
            writer.rect(rect)
        }
    }

    // MARK: Text

    /// The font text is drawn in; `.body` until set.
    public func setFont(_ font: Font) {
        state.font = font
    }

    public var font: Font {
        state.font ?? .body
    }

    /// One line, placed so `anchor` of its bounds is at `point`.
    public func draw(_ text: String, at point: Point, anchor: UnitPoint = .center) {
        guard !text.isEmpty else { return }
        writeFont()
        writer.command(.textAtPoint) { writer in
            writer.point(point)
            writer.u8(Self.anchorCode(anchor))
            writer.string(text)
        }
    }

    /// Wrapped to the rect's width, from its top, and cut at its bottom.
    public func draw(_ text: String, in rect: Rect, alignment: TextAlignment = .leading) {
        guard !text.isEmpty, !rect.isEmpty else { return }
        writeFont()
        writer.command(.textInRect) { writer in
            writer.rect(rect)
            writer.u8(alignment == .leading ? 0 : alignment == .center ? 1 : 2)
            writer.string(text)
        }
    }

    private func writeFont() {
        let font = self.font
        guard font != writtenFont else { return }
        writtenFont = font
        let host = DrawingFonts.font(for: font)
        retain(host)
        writer.command(.font) { $0.u32(UInt32(bitPattern: host.identifier())) }
    }

    /// The nine anchors, row by row from the top leading one; a point
    /// between them is the nearest.
    static func anchorCode(_ anchor: UnitPoint) -> UInt8 {
        func third(_ value: Double) -> UInt8 {
            value < 1.0 / 3 ? 0 : value > 2.0 / 3 ? 2 : 1
        }
        return third(anchor.y) * 3 + third(anchor.x)
    }

    /// The host has replayed what was recorded: what it named can go.
    func releaseRetained() {
        retained = []
    }

    private func retain(_ object: AnyObject) {
        if !retained.contains(where: { $0 === object }) {
            retained.append(object)
        }
    }

    /// Back to an empty drawing, keeping nothing. Saved states and the font
    /// written go too.
    func reset() {
        writer.reset()
        state = State()
        saved = []
        devicePath = Path()
        retained = []
        writtenFont = nil
    }
}
