import DynamicDrawing
import DynamicSwiftUI

/// Reads a drawing (`Documentation/Contracts/Drawing.md`, "A drawing") and
/// replays it into a `DrawingRenderer`, resolving fonts and images by
/// identifier and named colors through `HostDrawing.backend`.
///
/// A command it doesn't know is skipped by its length, and said once in
/// `HostDrawing.log`. A malformed one stops the replay; what was drawn
/// before stays. A player keeps the font across drawings, so a bitmap's
/// drawings carry on from one another.
public final class DrawingPlayer {

    /// Draws named colors for the dark appearance.
    public var dark: Bool

    /// The font text is drawn in, and those saved.
    private var font: HostFont?

    private var savedFonts: [HostFont?] = []

    nonisolated(unsafe) private static var reportedUnknown: Set<UInt8> = []

    public init(dark: Bool = false) {
        self.dark = dark
    }

    /// Why a drawing stopped.
    public enum Failure: Error, Equatable {
        case badHeader
        case truncated(command: UInt8)
        case badValue(command: UInt8)
    }

    /// Replays `drawing`. Returns why it stopped early, if it did.
    @discardableResult
    public func play(_ drawing: [UInt8], into renderer: any DrawingRenderer) -> Failure? {
        guard drawing.count >= 8, Array(drawing.prefix(4)) == [0x52, 0x54, 0x44, 0x52] else {
            HostDrawing.log("A drawing without its header wasn't drawn.")
            return .badHeader
        }
        var offset = 8
        while offset < drawing.count {
            let opcode = drawing[offset]
            offset += 1
            guard let length = Self.leb128(drawing, &offset), offset + length <= drawing.count else {
                HostDrawing.log("A drawing stopped at a command cut short (\(opcode)).")
                return .truncated(command: opcode)
            }
            var reader = Reader(bytes: drawing, offset: offset, end: offset + length)
            offset += length
            guard let command = DrawingOpcode(rawValue: opcode) else {
                if !Self.reportedUnknown.contains(opcode) {
                    Self.reportedUnknown.insert(opcode)
                    HostDrawing.log("Drawing command \(opcode) isn't known to this host, and was skipped.")
                }
                continue
            }
            guard perform(command, &reader, renderer) else {
                HostDrawing.log("A drawing stopped at a malformed command (\(opcode)).")
                return .badValue(command: opcode)
            }
        }
        return nil
    }

    private func perform(_ command: DrawingOpcode, _ reader: inout Reader, _ renderer: any DrawingRenderer) -> Bool {
        switch command {
        case .save:
            savedFonts.append(font)
            renderer.save()
        case .restore:
            if let last = savedFonts.popLast() { font = last }
            renderer.restore()
        case .concatenate:
            guard let t = reader.transform() else { return false }
            renderer.concatenate(t)
        case .alpha:
            guard let alpha = reader.float() else { return false }
            renderer.setAlpha(Swift.max(0, Swift.min(1, alpha)))
        case .blendMode:
            guard let raw = reader.u8() else { return false }
            renderer.setBlendMode(BlendMode(rawValue: raw) ?? .normal)
        case .antialias:
            guard let raw = reader.u8() else { return false }
            renderer.setAntialias(raw != 0)
        case .fillColor:
            guard let color = color(&reader) else { return false }
            renderer.setFillColor(color)
        case .strokeColor:
            guard let color = color(&reader) else { return false }
            renderer.setStrokeColor(color)
        case .strokeStyle:
            guard let width = reader.float(), let cap = reader.u8(), let join = reader.u8(),
                  let miter = reader.float(), let phase = reader.float(), let count = reader.u16() else { return false }
            var dash: [Double] = []
            for _ in 0..<count {
                guard let length = reader.float() else { return false }
                dash.append(length)
            }
            renderer.setStrokeStyle(StrokeStyle(lineWidth: width, lineCap: LineCap(rawValue: cap) ?? .butt, lineJoin: LineJoin(rawValue: join) ?? .miter, miterLimit: miter, dash: dash, dashPhase: phase))
        case .shadow:
            if reader.isAtEnd {
                renderer.setShadow(nil)
            } else {
                guard let x = reader.float(), let y = reader.float(), let blur = reader.float(), let color = color(&reader) else { return false }
                renderer.setShadow(DrawingShadow(offset: Size(width: x, height: y), blur: blur, color: color))
            }
        case .font:
            guard let identifier = reader.u32() else { return false }
            font = HostFont.font(Int32(bitPattern: identifier))
            if font == nil {
                HostDrawing.log("A drawing named font \(identifier), which this host doesn't have.")
            }
        case .fill:
            guard let rule = reader.u8(), let path = reader.path() else { return false }
            renderer.fill(path, rule: FillRule(rawValue: rule) ?? .winding)
        case .stroke:
            guard let path = reader.path() else { return false }
            renderer.stroke(path)
        case .clip:
            guard let rule = reader.u8(), let path = reader.path() else { return false }
            renderer.clip(path, rule: FillRule(rawValue: rule) ?? .winding)
        case .clear:
            guard let rect = reader.rect() else { return false }
            renderer.clear(rect)
        case .image:
            guard let identifier = reader.u32(), let rect = reader.rect() else { return false }
            if let image = HostImages.image(Int32(bitPattern: identifier)) {
                renderer.draw(image, in: rect)
            } else {
                HostDrawing.log("A drawing named image \(identifier), which this host doesn't have.")
            }
        case .textAtPoint:
            guard let point = reader.point(), let anchor = reader.u8(), anchor < 9, let text = reader.string() else { return false }
            if let handle = font?.handle {
                let unit = UnitPoint(x: Double(anchor % 3) / 2, y: Double(anchor / 3) / 2)
                renderer.draw(text, font: handle, at: point, anchor: unit)
            }
        case .textInRect:
            guard let rect = reader.rect(), let alignment = reader.u8(), let text = reader.string() else { return false }
            if let handle = font?.handle {
                renderer.draw(text, font: handle, in: rect, alignment: alignment == 1 ? .center : alignment == 2 ? .trailing : .leading)
            }
        case .linearGradient:
            guard let gradient = gradient(&reader), let start = reader.point(), let end = reader.point(), let options = reader.u8() else { return false }
            renderer.drawLinearGradient(gradient, start: start, end: end, options: GradientOptions(rawValue: options))
        case .radialGradient:
            guard let gradient = gradient(&reader), let startCenter = reader.point(), let startRadius = reader.float(),
                  let endCenter = reader.point(), let endRadius = reader.float(), let options = reader.u8() else { return false }
            renderer.drawRadialGradient(gradient, startCenter: startCenter, startRadius: startRadius, endCenter: endCenter, endRadius: endRadius, options: GradientOptions(rawValue: options))
        case .beginLayer:
            savedFonts.append(font)
            renderer.beginLayer()
        case .endLayer:
            if let last = savedFonts.popLast() { font = last }
            renderer.endLayer()
        }
        return true
    }

    private func color(_ reader: inout Reader) -> DrawingColor? {
        guard let kind = reader.u8() else { return nil }
        switch kind {
        case 0:
            guard let r = reader.float(), let g = reader.float(), let b = reader.float(), let a = reader.float() else { return nil }
            return DrawingColor(red: r, green: g, blue: b, alpha: a)
        case 1:
            guard let opacity = reader.float(), let name = reader.string() else { return nil }
            var color = HostDrawing.backend?.color(named: name, dark: dark) ?? (name == "clear" ? .clear : .black)
            color.alpha *= opacity
            return color
        default:
            return nil
        }
    }

    private func gradient(_ reader: inout Reader) -> DrawingGradient? {
        guard let count = reader.u16() else { return nil }
        var stops: [DrawingGradient.Stop] = []
        for _ in 0..<count {
            guard let location = reader.float(), let color = color(&reader) else { return nil }
            stops.append(DrawingGradient.Stop(location: location, color: color))
        }
        return DrawingGradient(stops: stops)
    }

    static func leb128(_ bytes: [UInt8], _ offset: inout Int) -> Int? {
        var value = 0
        var shift = 0
        while offset < bytes.count, shift < 35 {
            let byte = bytes[offset]
            offset += 1
            value |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    /// One command's payload.
    struct Reader {

        let bytes: [UInt8]
        var offset: Int
        let end: Int

        var isAtEnd: Bool {
            offset >= end
        }

        mutating func u8() -> UInt8? {
            guard offset + 1 <= end else { return nil }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func u16() -> UInt16? {
            guard offset + 2 <= end else { return nil }
            defer { offset += 2 }
            return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }

        mutating func u32() -> UInt32? {
            guard offset + 4 <= end else { return nil }
            var value: UInt32 = 0
            for index in 0..<4 {
                value |= UInt32(bytes[offset + index]) << UInt32(8 * index)
            }
            offset += 4
            return value
        }

        mutating func float() -> Double? {
            guard let bits = u32() else { return nil }
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        }

        mutating func point() -> Point? {
            guard let x = float(), let y = float() else { return nil }
            return Point(x: x, y: y)
        }

        mutating func rect() -> Rect? {
            guard let x = float(), let y = float(), let width = float(), let height = float() else { return nil }
            return Rect(x: x, y: y, width: width, height: height)
        }

        mutating func transform() -> AffineTransform? {
            guard let a = float(), let b = float(), let c = float(), let d = float(), let tx = float(), let ty = float() else { return nil }
            return AffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
        }

        mutating func string() -> String? {
            guard let length = u32(), offset + Int(length) <= end else { return nil }
            defer { offset += Int(length) }
            return String(decoding: bytes[offset..<offset + Int(length)], as: UTF8.self)
        }

        mutating func path() -> Path? {
            guard let count = u32(), Int(count) <= (end - offset) else { return nil }
            var path = Path()
            for _ in 0..<count {
                guard let verb = u8() else { return nil }
                switch verb {
                case 0:
                    guard let p = point() else { return nil }
                    path.move(to: p)
                case 1:
                    guard let p = point() else { return nil }
                    path.addLine(to: p)
                case 2:
                    guard let c = point(), let p = point() else { return nil }
                    path.addQuadCurve(to: p, control: c)
                case 3:
                    guard let c1 = point(), let c2 = point(), let p = point() else { return nil }
                    path.addCurve(to: p, control1: c1, control2: c2)
                case 4:
                    path.closeSubpath()
                default:
                    return nil
                }
            }
            return path
        }
    }
}
