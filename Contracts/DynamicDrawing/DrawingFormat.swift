import DynamicUI
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// The drawing format's commands (`Documentation/Contracts/Drawing.md`,
/// "A drawing"). Hosts read the same numbers.
public enum DrawingOpcode: UInt8, Sendable {
    case save = 0x01
    case restore = 0x02
    case concatenate = 0x03
    case alpha = 0x04
    case blendMode = 0x05
    case antialias = 0x06
    case fillColor = 0x07
    case strokeColor = 0x08
    case strokeStyle = 0x09
    case shadow = 0x0A
    case font = 0x0B
    case fill = 0x10
    case stroke = 0x11
    case clip = 0x12
    case clear = 0x13
    case image = 0x14
    case textAtPoint = 0x15
    case textInRect = 0x16
    case linearGradient = 0x17
    case radialGradient = 0x18
    case beginLayer = 0x19
    case endLayer = 0x1A
}

/// Writes a drawing: `"RTDR"`, a version, then each command as its opcode,
/// its payload's length in LEB128, and the payload. Little-endian, every
/// number a 32-bit float unless said otherwise.
struct DrawingWriter {

    static let header: [UInt8] = [0x52, 0x54, 0x44, 0x52, 1, 0, 0, 0]

    private(set) var bytes: [UInt8] = DrawingWriter.header

    /// The command being written.
    private var payload: [UInt8] = []

    var isEmpty: Bool {
        bytes.count == Self.header.count
    }

    mutating func reset() {
        bytes = Self.header
    }

    /// Writes one command, whose payload `write` makes.
    mutating func command(_ opcode: DrawingOpcode, _ write: (inout DrawingWriter) -> Void = { _ in }) {
        payload = []
        write(&self)
        bytes.append(opcode.rawValue)
        var length = UInt32(payload.count)
        repeat {
            var byte = UInt8(length & 0x7F)
            length >>= 7
            if length != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while length != 0
        bytes.append(contentsOf: payload)
        payload = []
    }

    // MARK: Payload

    mutating func u8(_ value: UInt8) {
        payload.append(value)
    }

    mutating func u16(_ value: UInt16) {
        payload.append(UInt8(value & 0xFF))
        payload.append(UInt8(value >> 8))
    }

    mutating func u32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            payload.append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }

    mutating func float(_ value: Double) {
        u32(Float(value).bitPattern)
    }

    mutating func point(_ point: Point) {
        float(point.x)
        float(point.y)
    }

    mutating func rect(_ rect: Rect) {
        let rect = rect.standardized
        float(rect.minX)
        float(rect.minY)
        float(rect.width)
        float(rect.height)
    }

    mutating func string(_ text: String) {
        let utf8 = Array(text.utf8)
        u32(UInt32(utf8.count))
        payload.append(contentsOf: utf8)
    }

    /// `0` and sRGB components, not premultiplied; or `1`, an opacity and a
    /// name the host resolves for the appearance it draws in.
    mutating func color(_ color: Color) {
        if let named = color._named {
            u8(1)
            float(named.opacity)
            string(named.name)
        } else {
            let argb = color._argb ?? 0
            u8(0)
            float(Double((argb >> 16) & 0xFF) / 255)
            float(Double((argb >> 8) & 0xFF) / 255)
            float(Double(argb & 0xFF) / 255)
            float(Double(argb >> 24) / 255)
        }
    }

    mutating func gradient(_ gradient: Gradient) {
        u16(UInt16(clamping: gradient.stops.count))
        for stop in gradient.stops.prefix(Int(UInt16.max)) {
            float(stop.location)
            color(stop.color)
        }
    }

    /// A count, then each element: a verb (`0` move, `1` line, `2`
    /// quadratic, `3` cubic, `4` close) and its points.
    mutating func path(_ path: Path) {
        u32(UInt32(path.elements.count))
        for element in path.elements {
            switch element {
            case .move(let p):
                u8(0); point(p)
            case .line(let p):
                u8(1); point(p)
            case .quadCurve(let p, let c):
                u8(2); point(c); point(p)
            case .curve(let p, let c1, let c2):
                u8(3); point(c1); point(c2); point(p)
            case .closeSubpath:
                u8(4)
            }
        }
    }

    mutating func transform(_ t: AffineTransform) {
        float(t.a); float(t.b); float(t.c); float(t.d); float(t.tx); float(t.ty)
    }
}
