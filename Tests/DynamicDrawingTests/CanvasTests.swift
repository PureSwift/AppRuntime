import Foundation
import Testing
@testable import DynamicDrawing
import DynamicObservation
import DynamicRuntime
@testable import DynamicSwiftUI
import DynamicUI
import RuntimeDrawing
import RuntimeNative

/// A value a canvas's closure reads, observed as an `@Observable` class's
/// would be, without the macro, which Foundation's makes ambiguous here.
final class Level: DynamicObservation.Observable {

    private let registrar = DynamicObservation.ObservationRegistrar()

    private var stored = 0.25

    var value: Double {
        get {
            registrar.access(self, propertyIndex: 0)
            return stored
        }
        set {
            registrar.withMutation(of: self, propertyIndex: 0) { stored = newValue }
        }
    }
}

struct GaugeView: View {
    let level: Level
    var body: some View {
        Canvas { context, size in
            context.setFillColor(.orange)
            context.fill(Rect(x: 0, y: 0, width: size.width * level.value, height: size.height))
        }
    }
}

struct Triangle: Shape {
    func path(in rect: Rect) -> Path {
        var path = Path()
        path.move(to: Point(x: rect.midX, y: rect.minY))
        path.addLine(to: Point(x: rect.maxX, y: rect.maxY))
        path.addLine(to: Point(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct Shapes: View {
    var body: some View {
        VStack {
            Triangle().fill(.orange)
            Triangle().stroke(.blue, lineWidth: 2)
            Triangle()
            Circle().fill(.red)
        }
    }
}

/// The canvas, its drawing and the host's player. Part of
/// `DynamicDrawingTests`, which is serialized.
extension DynamicDrawingTests {

    func backend() -> MemoryDrawingBackend {
        let backend = MemoryDrawingBackend()
        HostDrawing.backend = backend
        DrawingFonts.reset()
        return backend
    }

    /// A context's drawing, replayed by the host's player.
    func replay(_ context: GraphicsContext, dark: Bool = false) -> [String] {
        let recorder = RecordingRenderer()
        #expect(DrawingPlayer(dark: dark).play(context.drawing, into: recorder) == nil)
        return recorder.calls
    }

    // MARK: Contracts

    @Test func theCanvasContractsKeysAndSignatures() {
        func method(_ descriptor: ContractDescriptor, _ key: String) -> MethodDescriptor? {
            descriptor.methods.first { $0.key == key }
        }
        let canvas = DrawingCanvasProxy.descriptor
        #expect(canvas.name == "org.pureswift.drawing.Canvas" && canvas.capability == nil)
        #expect(method(canvas, "make:")?.kind == .constructor)
        #expect(method(canvas, "setNeedsDisplay")?.signature == Signature("()V"))
        #expect(method(DrawingCanvasDelegateProxy.descriptor, "draw:width:height:scale:")?.signature == Signature("(OFFF)O"), "the drawing, answered at once")
        let bitmap = DrawingBitmapProxy.descriptor
        #expect(method(bitmap, "make:height:scale:opaque:")?.signature == Signature("(FFFZ)O"))
        #expect(method(bitmap, "draw:")?.signature == Signature("(O)V"))
        #expect(method(bitmap, "image")?.signature == Signature("()O"))
        let font = DrawingFontProxy.descriptor
        #expect(method(font, "make:size:style:weight:design:italic:")?.signature == Signature("(OFIIIZ)O"))
        #expect(method(font, "measure:maxWidth:")?.signature == Signature("(OF)O"))
        let descriptors = [canvas, DrawingCanvasDelegateProxy.descriptor, bitmap, font]
        #expect(ContractMetadata.decode(descriptors.flatMap(ContractMetadata.encode)) == descriptors)
    }

    // MARK: Path

    @Test func pathsAreBuiltAndAskedInTheGuest() {
        var path = Path()
        #expect(path.isEmpty && path.currentPoint == nil && path.boundingRect.isNull)
        path.addLine(to: Point(x: 1, y: 1))
        #expect(path.elements == [.move(to: Point(x: 1, y: 1))], "a line on an empty path is a move")
        path.closeSubpath()
        path.closeSubpath()
        #expect(path.elements.count == 2, "closed once")

        let square = Path(Rect(x: 0, y: 0, width: 10, height: 10))
        #expect(square.elements.count == 5 && square.boundingRect == Rect(x: 0, y: 0, width: 10, height: 10))
        #expect(square.contains(Point(x: 5, y: 5)) && !square.contains(Point(x: 11, y: 5)))

        // Two squares the same way round: inside the inner one, the path
        // winds twice, and crosses twice.
        var nested = square
        nested.addRect(Rect(x: 2, y: 2, width: 6, height: 6))
        #expect(nested.contains(Point(x: 5, y: 5), using: .winding))
        #expect(!nested.contains(Point(x: 5, y: 5), using: .evenOdd))
        #expect(nested.contains(Point(x: 1, y: 5), using: .evenOdd))

        let circle = Path(ellipseIn: Rect(x: 0, y: 0, width: 20, height: 20))
        #expect(circle.boundingRect == Rect(x: 0, y: 0, width: 20, height: 20))
        #expect(circle.contains(Point(x: 10, y: 10)) && !circle.contains(Point(x: 1, y: 1)), "a corner is outside")

        let moved = square.applying(AffineTransform(translationX: 5, y: 0))
        #expect(moved.boundingRect.minX == 5 && moved.currentPoint == Point(x: 5, y: 0), "closed: back at the start")

        let rounded = Path(roundedRect: Rect(x: 0, y: 0, width: 10, height: 4), cornerRadius: 10)
        #expect(rounded.boundingRect == Rect(x: 0, y: 0, width: 10, height: 4), "a corner no larger than half a side")
    }

    @Test func arcsAreCurvesThatEndWhereTheyShould() throws {
        var quarter = Path()
        quarter.addArc(center: .zero, radius: 10, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        #expect(quarter.elements.count == 2, "a move and one cubic")
        let end = try #require(quarter.currentPoint)
        #expect(abs(end.x) < 1e-9 && abs(end.y - 10) < 1e-9, "increasing angles: clockwise on screen, y down")

        var other = Path()
        other.addArc(center: .zero, radius: 10, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        #expect(other.elements.count == 4, "the long way round: three quarters")

        // A rounded corner, as CoreGraphics' tangent arc draws it.
        var corner = Path()
        corner.move(to: .zero)
        corner.addArc(tangent1End: Point(x: 10, y: 0), tangent2End: Point(x: 10, y: 10), radius: 2)
        guard case .line(let start) = corner.elements[1] else {
            Issue.record("a line to where the arc starts")
            return
        }
        #expect(abs(start.x - 8) < 1e-9 && abs(start.y) < 1e-9)
        let finish = try #require(corner.currentPoint)
        #expect(abs(finish.x - 10) < 1e-9 && abs(finish.y - 2) < 1e-9)
    }

    // MARK: Recording

    @Test func aContextRecordsWhatThePlayerReplays() {
        _ = backend()
        let context = GraphicsContext()
        context.saveGState()
        context.translateBy(x: 10, y: 20)
        context.setFillColor(Color(red: 1, green: 0, blue: 0))
        context.addRect(Rect(x: 0, y: 0, width: 4, height: 2))
        #expect(context.boundingBoxOfPath == Rect(x: 0, y: 0, width: 4, height: 2), "in user space")
        context.fillPath()
        #expect(context.isPathEmpty, "painting takes the path")
        context.setLineWidth(3)
        context.setLineDash(phase: 1, lengths: [2, 1])
        context.setStrokeColor(.primary)
        context.move(to: .zero)
        context.addLine(to: Point(x: 5, y: 0))
        #expect(context.currentPoint == Point(x: 5, y: 0))
        context.strokePath()
        context.restoreGState()
        context.restoreGState()
        #expect(context.ctm.isIdentity)
        context.setAlpha(0.5)
        context.setBlendMode(.multiply)
        context.setShadow(offset: Size(width: 1, height: 2), blur: 3, color: .black)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.clip(to: Rect(x: 0, y: 0, width: 8, height: 8))
        context.clear(Rect(x: 1, y: 1, width: 2, height: 2))
        context.drawLinearGradient(Gradient(colors: [.white, .black]), start: .zero, end: Point(x: 0, y: 10), options: .drawsAfterEndLocation)
        context.beginTransparencyLayer()
        context.endTransparencyLayer()
        context.fill(Path(Rect(x: 0, y: 0, width: 1, height: 1)), with: .orange)

        #expect(replay(context) == [
            "save",
            "concatenate 1 0 0 1 10 20",
            "fill color 1 0 0 1",
            "fill winding M 0 0 L 4 0 L 4 2 L 0 2 Z",
            "stroke style 3 butt miter 10 [] 0",
            "stroke style 3 butt miter 10 [2,1] 1",
            "stroke color 0 0 0 1",
            "stroke M 0 0 L 5 0",
            "restore",
            "alpha 0.5",
            "blend multiply",
            "shadow 1 2 3 0 0 0 1",
            "no shadow",
            "clip winding M 0 0 L 8 0 L 8 8 L 0 8 Z",
            "clear 1 1 2 2",
            "linear 0:1 1 1 1,1:0 0 0 1 0 0 0 10 2",
            "begin layer",
            "end layer",
            "save",
            "fill color 1 0.584 0 1",
            "fill winding M 0 0 L 1 0 L 1 1 L 0 1 Z",
            "restore",
        ])
    }

    /// The format is little-endian on every host, a big-endian PowerPC's
    /// included (`Documentation/PowerPC.md`).
    @Test func aDrawingsNumbersAreLowByteFirst() {
        var writer = DrawingWriter()
        writer.command(.alpha) { $0.float(0.5) }          // 0x3F00_0000
        writer.command(.font) { $0.u32(0x0102_0304) }
        writer.command(.strokeStyle) { $0.u16(0x0A0B) }
        #expect(writer.bytes == DrawingWriter.header + [
            0x04, 4, 0, 0, 0, 0x3F,
            0x0B, 4, 4, 3, 2, 1,
            0x09, 2, 0x0B, 0x0A,
        ])
    }

    @Test func aPathKeepsTheTransformItWasBuiltIn() {
        _ = backend()
        let context = GraphicsContext()
        context.translateBy(x: 100, y: 0)
        context.addRect(Rect(x: 0, y: 0, width: 1, height: 1))
        // Built at x 100 on the canvas; filled after a scale, so it goes
        // to the host in that space, where the host's transform puts it
        // back.
        context.scaleBy(x: 2, y: 2)
        context.fillPath()
        #expect(replay(context) == [
            "concatenate 1 0 0 1 100 0",
            "concatenate 2 0 0 2 0 0",
            "fill winding M 0 0 L 0.5 0 L 0.5 0.5 L 0 0.5 Z",
        ])
    }

    @Test func namedColorsFollowTheAppearance() {
        _ = backend()
        let context = GraphicsContext()
        context.setFillColor(.primary)
        context.setFillColor(Color.primary.opacity(0.5))
        context.setFillColor(Color(named: "nameless"))
        #expect(replay(context, dark: false) == ["fill color 0 0 0 1", "fill color 0 0 0 0.5", "fill color 0 0 0 1"])
        #expect(replay(context, dark: true) == ["fill color 1 1 1 1", "fill color 1 1 1 0.5", "fill color 0 0 0 1"], "the same recording, drawn dark")
    }

    @Test func textIsDrawnInTheHostsFont() throws {
        let host = backend()
        let context = GraphicsContext()
        context.draw("Hi", at: Point(x: 10, y: 10))
        context.setFont(.system(size: 20, weight: .semibold))
        context.draw("72%", at: Point(x: 50, y: 50), anchor: .center)
        context.draw("Wrapped", in: Rect(x: 0, y: 0, width: 30, height: 40), alignment: .center)
        #expect(replay(context) == [
            "text \"Hi\" at 10 10 anchor 0.5 0.5",
            "text \"72%\" at 50 50 anchor 0.5 0.5",
            "text \"Wrapped\" in 0 0 30 40 center",
        ])
        #expect(host.fonts.map(\.textStyle) == ["body", nil], "`.body` until set; one font each")
        #expect(host.fonts.last?.size == 20 && host.fonts.last?.weight == .semibold)
        #expect(GraphicsContext.anchorCode(.topLeading) == 0 && GraphicsContext.anchorCode(.bottomTrailing) == 8)

        // Measured as the host lays it out.
        let font = Font.system(size: 10)
        #expect(font.measure("abcd") == Size(width: 20, height: 10))
        #expect(font.measure("abcdefgh", maxWidth: 25) == Size(width: 25, height: 20), "wrapped onto two lines")
        #expect(font.metrics().ascent == 8 && font.metrics().lineHeight == 10)
        #expect(host.fonts.count == 3, "the same font is made once")
    }

    @Test func anImageIsDrawnByItsHostImage() throws {
        _ = backend()
        let image = try #require(Image(pixels: [UInt8](repeating: 255, count: 16), width: 2, height: 2))
        let identifier = try #require(image._hostImageIdentifier)
        let context = GraphicsContext()
        context.draw(image, in: Rect(x: 0, y: 0, width: 20, height: 20))
        context.draw(Image("bundled"), in: Rect(x: 0, y: 0, width: 20, height: 20))
        #expect(replay(context) == ["image \(identifier) 0 0 20 20"], "a named image draws nothing yet")
        #expect(context.retained.count == 1, "kept while the drawing can be replayed")
    }

    // MARK: Canvas

    @Test func aCanvasIsDrawnWhenTheHostAsks() throws {
        _ = backend()
        var redraws: [Int32] = []
        HostDrawing.canvasNeedsDisplay = { redraws.append($0) }
        let level = Level()
        let sink = DrawingSink()
        let graph = ViewGraph(GaugeView(level: level), sink: sink)
        graph.update()
        let node = try #require(sink.screen?.first("Canvas"))
        let identifier = try #require(node.props["canvas"]?.int)
        let canvas = try #require(HostCanvas.canvas(for: Int32(identifier)))
        #expect(canvas.needsDisplay && redraws.isEmpty, "nothing drawn before the host has a size")

        let recorder = RecordingRenderer()
        #expect(canvas.play(width: 100, height: 10, scale: 2, into: recorder) == nil)
        #expect(recorder.calls == ["fill color 1 0.584 0 1", "fill winding M 0 0 L 25 0 L 25 10 L 0 10 Z"])
        #expect(!canvas.needsDisplay)

        // What the closure read changed: the host is asked to draw again.
        level.value = 0.5
        #expect(redraws == [Int32(identifier)] && canvas.needsDisplay)
        recorder.removeAll()
        canvas.play(width: 100, height: 10, scale: 2, into: recorder)
        #expect(recorder.calls.last == "fill winding M 0 0 L 50 0 L 50 10 L 0 10 Z")

        // The view updated with the canvas there: drawn again, the same
        // canvas.
        graph.setNeedsUpdate()
        graph.update()
        #expect(redraws.count == 2)
        #expect(sink.screen?.first("Canvas")?.props["canvas"]?.int == identifier)
    }

    @Test func anAppsShapeIsACanvasOfItsPath() throws {
        _ = backend()
        let sink = DrawingSink()
        let graph = ViewGraph(Shapes(), sink: sink)
        graph.update()
        let stack = try #require(sink.screen?.first("VStack"))
        #expect(stack.children.map(\.type) == ["Canvas", "Canvas", "Canvas", "Shape"], "the built-in shape stays a node")
        #expect(stack.children[3].props["fill"] != nil)

        func drawing(_ index: Int) throws -> [String] {
            let identifier = try #require(stack.children[index].props["canvas"]?.int)
            let recorder = RecordingRenderer()
            try #require(HostCanvas.canvas(for: Int32(identifier))).play(width: 10, height: 8, scale: 1, into: recorder)
            return recorder.calls
        }
        let triangle = "M 5 0 L 10 8 L 0 8 Z"
        #expect(try drawing(0) == ["save", "fill color 1 0.584 0 1", "fill winding \(triangle)", "restore"])
        #expect(try drawing(1) == ["save", "stroke color 0 0.478 1 1", "stroke style 2 butt miter 10 [] 0", "stroke \(triangle)", "restore"])
        #expect(try drawing(2) == ["save", "fill color 0 0 0 1", "fill winding \(triangle)", "restore"], "unstyled: the foreground color")
    }

    // MARK: Bitmaps

    @Test func aBitmapDrawsOffScreenAndIsReadBack() async throws {
        let host = backend()
        #expect(BitmapContext(width: 3000, height: 10, scale: 2) == nil, "6000 pixels across is more than the host takes")
        #expect(BitmapContext(width: 0, height: 10) == nil)
        let context = try #require(BitmapContext(width: 10, height: 5, scale: 2))
        #expect(context.pixelWidth == 20 && context.pixelHeight == 10)
        let target = try #require(host.bitmaps.last)
        #expect(target.pixelWidth == 20 && target.pixelHeight == 10 && !target.opaque)
        #expect(target.recorder.calls == ["concatenate 2 0 0 2 0 0"], "drawings are in points")

        context.setFillColor(.orange)
        context.fill(Rect(x: 0, y: 0, width: 10, height: 5))
        #expect(target.recorder.calls.count == 1, "nothing sent until it's read")
        let pixels = try await context.pixels()
        #expect(pixels.count == 20 * 10 * 4)
        #expect(pixels[0] == 3, "read after what was drawn")

        // The state carries on: the fill color isn't sent again.
        context.fillEllipse(in: Rect(x: 0, y: 0, width: 5, height: 5))
        let png = try await context.png()
        #expect(png.prefix(4) == [0x89, 0x50, 0x4E, 0x47] && png[4] == 20)
        #expect(target.recorder.calls.count == 4 && target.recorder.calls[3].hasPrefix("fill winding M 5 2.5 C"))

        // Made into an image, the size is in points.
        let image = context.makeImage()
        let size = try await image.size
        #expect(size == Size(width: 10, height: 5))
        #expect(context.drawing == DrawingWriter.header, "what was sent isn't kept")
    }
}
