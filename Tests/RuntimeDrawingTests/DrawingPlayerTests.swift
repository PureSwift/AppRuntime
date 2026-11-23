import Testing
import DynamicDrawing
import DynamicSwiftUI
@testable import RuntimeDrawing

/// Writes a drawing by hand, as a guest from elsewhere might.
struct Drawing {

    var bytes: [UInt8] = [0x52, 0x54, 0x44, 0x52, 1, 0, 0, 0]

    mutating func command(_ opcode: UInt8, _ payload: [UInt8]) {
        bytes.append(opcode)
        var length = payload.count
        repeat {
            var byte = UInt8(length & 0x7F)
            length >>= 7
            if length != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while length != 0
        bytes += payload
    }

    static func float(_ value: Float) -> [UInt8] {
        let bits = value.bitPattern
        return [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24)]
    }

    static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)]
    }
}

/// The player against hand-written drawings, and the bitmap and font
/// contracts over the memory backend. Part of `RuntimeDrawingTests`, which
/// is serialized.
extension RuntimeDrawingTests {

    func player() -> (DrawingPlayer, RecordingRenderer) {
        HostDrawing.reset()
        HostDrawing.log = { RuntimeDrawingTests.logged.append($0) }
        HostDrawing.backend = MemoryDrawingBackend()
        return (DrawingPlayer(), RecordingRenderer())
    }

    @Test func aDrawingNeedsItsHeader() {
        let (player, recorder) = player()
        #expect(player.play([0x52, 0x54, 0x44], into: recorder) == .badHeader)
        #expect(player.play([0x50, 0x4E, 0x47, 0x00, 1, 0, 0, 0], into: recorder) == .badHeader)
        #expect(player.play(Drawing().bytes, into: recorder) == nil, "an empty drawing draws nothing")
        #expect(recorder.calls.isEmpty)
    }

    @Test func anUnknownCommandIsSkippedAndSaidOnce() {
        let (player, recorder) = player()
        var drawing = Drawing()
        drawing.command(0x7E, [1, 2, 3])
        drawing.command(0x01, [])
        drawing.command(0x7E, [])
        drawing.command(0x02, [])
        #expect(player.play(drawing.bytes, into: recorder) == nil)
        #expect(recorder.calls == ["save", "restore"])
        #expect(Self.logged.filter { $0.contains("126") }.count <= 1, "said once")
    }

    @Test func aMalformedCommandStopsTheDrawing() {
        let (player, recorder) = player()
        var drawing = Drawing()
        drawing.command(0x04, Drawing.float(0.25))
        drawing.command(0x04, [0, 0])              // an alpha cut short
        drawing.command(0x01, [])
        #expect(player.play(drawing.bytes, into: recorder) == .badValue(command: 0x04))
        #expect(recorder.calls == ["alpha 0.25"], "what came before stays")

        // A length past the end.
        var short = Drawing()
        short.bytes += [0x01, 0x05]
        #expect(player.play(short.bytes, into: recorder) == .truncated(command: 0x01))

        // A path with a verb that isn't one.
        var path = Drawing()
        path.command(0x11, Drawing.u32(1) + [9])
        #expect(player.play(path.bytes, into: recorder) == .badValue(command: 0x11))

        // Not a number.
        var nan = Drawing()
        nan.command(0x04, Drawing.float(.nan))
        #expect(player.play(nan.bytes, into: recorder) == .badValue(command: 0x04))
    }

    @Test func aLongPayloadsLengthTakesMoreBytes() {
        let (player, recorder) = player()
        let font = HostFont.make(name: nil, size: 12, style: 0, weight: 3, design: 0, italic: false)
        let text = String(repeating: "a", count: 300)
        var drawing = Drawing()
        drawing.command(0x0B, Drawing.u32(UInt32(bitPattern: font.identifier())))
        drawing.command(0x15, Drawing.float(1) + Drawing.float(2) + [0] + Drawing.u32(300) + Array(text.utf8))
        #expect(drawing.bytes[Drawing().bytes.count + 6] == 0x15 && drawing.bytes[Drawing().bytes.count + 7] & 0x80 != 0, "two bytes of length")
        #expect(player.play(drawing.bytes, into: recorder) == nil)
        #expect(recorder.calls == ["text \"\(text)\" at 1 2 anchor 0 0"])
        _ = font
    }

    @Test func fontsAndImagesTheHostDoesntHaveAreSkipped() {
        let (player, recorder) = player()
        var drawing = Drawing()
        drawing.command(0x14, Drawing.u32(9999) + Drawing.float(0) + Drawing.float(0) + Drawing.float(1) + Drawing.float(1))
        drawing.command(0x0B, Drawing.u32(9999))
        drawing.command(0x15, Drawing.float(0) + Drawing.float(0) + [4] + Drawing.u32(1) + [0x41])
        #expect(player.play(drawing.bytes, into: recorder) == nil)
        #expect(recorder.calls.isEmpty)
        #expect(Self.logged.contains { $0.contains("image 9999") } && Self.logged.contains { $0.contains("font 9999") })
    }

    @Test func aRestoreBringsBackTheFont() {
        let (player, recorder) = player()
        let small = HostFont.make(name: nil, size: 10, style: 0, weight: 3, design: 0, italic: false)
        let large = HostFont.make(name: "Avenir", size: 30, style: 0, weight: 6, design: 0, italic: true)
        #expect(large.description.name == "Avenir" && large.description.weight == .bold && large.description.italic)
        func text(_ letter: UInt8) -> [UInt8] {
            Drawing.float(0) + Drawing.float(0) + [0] + Drawing.u32(1) + [letter]
        }
        var drawing = Drawing()
        drawing.command(0x0B, Drawing.u32(UInt32(bitPattern: small.identifier())))
        drawing.command(0x01, [])
        drawing.command(0x0B, Drawing.u32(UInt32(bitPattern: large.identifier())))
        drawing.command(0x02, [])
        drawing.command(0x15, text(0x42))
        let fonts = Recorded()
        player.play(drawing.bytes, into: fonts)
        #expect(fonts.sizes == [10], "the font saved, not the one set after")
        _ = (small, large, recorder)
    }

    @Test func bitmapsAndFontsNeedABackend() {
        HostDrawing.reset()
        #expect(HostBitmap.make(width: 10, height: 10, scale: 1, opaque: false) == nil, "nothing to draw with")
        let font = HostFont.make(name: nil, size: 12, style: 7, weight: 3, design: 0, italic: false)
        #expect(font.description.textStyle == "body")
        #expect(font.measure("hello", maxWidth: 0) == HostFont.floats([0, 0]), "measures nothing")

        HostDrawing.backend = MemoryDrawingBackend()
        HostDrawing.maximumBitmapSide = 64
        #expect(HostBitmap.make(width: 33, height: 10, scale: 2, opaque: false) == nil, "66 pixels across")
        #expect(HostBitmap.make(width: 32, height: 10, scale: 2, opaque: true)?.pixelWidth == 64)
        #expect(HostBitmap.make(width: .infinity, height: 1, scale: 1, opaque: false) == nil)
        HostDrawing.reset()
    }
}

/// A recorder that also notes the size of each font text is drawn in.
final class Recorded: DrawingRenderer {
    var sizes: [Double] = []
    func save() { }
    func restore() { }
    func concatenate(_ transform: AffineTransform) { }
    func setAlpha(_ alpha: Double) { }
    func setBlendMode(_ mode: BlendMode) { }
    func setAntialias(_ antialias: Bool) { }
    func setFillColor(_ color: DrawingColor) { }
    func setStrokeColor(_ color: DrawingColor) { }
    func setStrokeStyle(_ style: StrokeStyle) { }
    func setShadow(_ shadow: DrawingShadow?) { }
    func fill(_ path: Path, rule: FillRule) { }
    func stroke(_ path: Path) { }
    func clip(_ path: Path, rule: FillRule) { }
    func clear(_ rect: Rect) { }
    func draw(_ image: HostImage, in rect: Rect) { }
    func draw(_ text: String, font: any DrawingFontHandle, at point: Point, anchor: UnitPoint) {
        sizes.append(font.measure("ab", maxWidth: nil).height)
    }
    func draw(_ text: String, font: any DrawingFontHandle, in rect: Rect, alignment: TextAlignment) { }
    func drawLinearGradient(_ gradient: DrawingGradient, start: Point, end: Point, options: GradientOptions) { }
    func drawRadialGradient(_ gradient: DrawingGradient, startCenter: Point, startRadius: Double, endCenter: Point, endRadius: Double, options: GradientOptions) { }
    func beginLayer() { }
    func endLayer() { }
}
