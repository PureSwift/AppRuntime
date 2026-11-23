import DynamicRuntime
import DynamicUI
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

extension Font {

    /// Its lines on this host, in points. Text is the platform's: another
    /// host gives other numbers.
    public func metrics() -> FontMetrics {
        let values = DrawingFonts.floats(DrawingFonts.font(for: self).metrics(), count: 5)
        return FontMetrics(ascent: values[0], descent: values[1], leading: values[2], capHeight: values[3], xHeight: values[4])
    }

    /// What `text` occupies when a `GraphicsContext` draws it in this font,
    /// on one line, or wrapped at `maxWidth`.
    public func measure(_ text: String, maxWidth: Double? = nil) -> Size {
        let values = DrawingFonts.floats(DrawingFonts.font(for: self).measure(text, maxWidth: Float(maxWidth ?? 0)), count: 2)
        return Size(width: values[0], height: values[1])
    }
}

/// The host's fonts, made once for each `Font` and kept: a drawing names
/// them by identifier, and a font is small.
enum DrawingFonts {

    nonisolated(unsafe) private static var made: [(font: Font, host: DrawingFontProxy)] = []

    static let styles = ["largeTitle", "title", "title2", "title3", "headline", "subheadline", "body", "callout", "footnote", "caption", "caption2"]

    static let weights = ["ultraLight", "thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black"]

    static let designs = ["default", "serif", "rounded", "monospaced"]

    static func font(for font: Font) -> DrawingFontProxy {
        if let found = made.first(where: { $0.font == font }) {
            return found.host
        }
        let props = font._props
        func string(_ key: String) -> String? {
            if case .string(let value)? = props[key] { return value }
            return nil
        }
        var size = 0.0
        if case .double(let value)? = props["size"] { size = value }
        let style = string("style").flatMap { name in styles.firstIndex(of: name).map { Int32($0 + 1) } } ?? 0
        let weight = string("weight").flatMap { weights.firstIndex(of: $0) }.map(Int32.init) ?? 3
        let design = string("design").flatMap { designs.firstIndex(of: $0) }.map(Int32.init) ?? 0
        let italic = props["italic"] == .bool(true)
        let host = DrawingFontProxy.make(name: string("name"), size: Float(size), style: style, weight: weight, design: design, italic: italic)
        made.append((font, host))
        return host
    }

    /// Forgets the host's fonts, for tests.
    static func reset() {
        made = []
    }

    /// Little-endian 32-bit floats; 0 for what's missing.
    static func floats(_ bytes: [UInt8], count: Int) -> [Double] {
        (0..<count).map { index in
            let offset = index * 4
            guard offset + 4 <= bytes.count else { return 0 }
            var bits: UInt32 = 0
            for byte in 0..<4 {
                bits |= UInt32(bytes[offset + byte]) << UInt32(8 * byte)
            }
            return Double(Float(bitPattern: bits))
        }
    }
}
