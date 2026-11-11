import DynamicUI

/// Lets app code written against SwiftUI use `CGFloat` without CoreGraphics.
public typealias CGFloat = Double

public enum HorizontalAlignment: String, Sendable {
    case leading, center, trailing
}

public enum VerticalAlignment: String, Sendable {
    case top, center, bottom
}

public struct Alignment: Equatable, Sendable {

    public var horizontal: HorizontalAlignment

    public var vertical: VerticalAlignment

    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let center = Alignment(horizontal: .center, vertical: .center)
    public static let leading = Alignment(horizontal: .leading, vertical: .center)
    public static let trailing = Alignment(horizontal: .trailing, vertical: .center)
    public static let top = Alignment(horizontal: .center, vertical: .top)
    public static let bottom = Alignment(horizontal: .center, vertical: .bottom)
    public static let topLeading = Alignment(horizontal: .leading, vertical: .top)
    public static let topTrailing = Alignment(horizontal: .trailing, vertical: .top)
    public static let bottomLeading = Alignment(horizontal: .leading, vertical: .bottom)
    public static let bottomTrailing = Alignment(horizontal: .trailing, vertical: .bottom)

    var props: [String: PropValue] {
        ["horizontal": .string(horizontal.rawValue), "vertical": .string(vertical.rawValue)]
    }
}

public enum TextAlignment: String, Sendable {
    case leading, center, trailing
}

public enum Edge: Sendable {

    case top, leading, bottom, trailing

    public struct Set: OptionSet, Sendable {

        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let top = Set(rawValue: 1 << 0)
        public static let leading = Set(rawValue: 1 << 1)
        public static let bottom = Set(rawValue: 1 << 2)
        public static let trailing = Set(rawValue: 1 << 3)
        public static let horizontal: Set = [.leading, .trailing]
        public static let vertical: Set = [.top, .bottom]
        public static let all: Set = [.top, .leading, .bottom, .trailing]
    }
}

public enum Axis: Sendable {

    case horizontal, vertical

    public struct Set: OptionSet, Sendable {

        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let horizontal = Set(rawValue: 1 << 0)
        public static let vertical = Set(rawValue: 1 << 1)
    }
}

/// A color: one of the platform's named colors, which follow its light and
/// dark appearance, or fixed RGBA. In the IR a named color is its name (or
/// `[name, opacity]`), a fixed one an `0xAARRGGBB` int.
public struct Color: Equatable, Sendable {

    enum Storage: Equatable, Sendable {
        case named(String, opacity: Double)
        case rgba(UInt32)
    }

    let storage: Storage

    init(named name: String) {
        self.storage = .named(name, opacity: 1)
    }

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        func channel(_ value: Double) -> UInt32 {
            UInt32(Swift.max(0, Swift.min(255, (value * 255).rounded())))
        }
        self.storage = .rgba(channel(opacity) << 24 | channel(red) << 16 | channel(green) << 8 | channel(blue))
    }

    public init(white: Double, opacity: Double = 1) {
        self.init(red: white, green: white, blue: white, opacity: opacity)
    }

    public static let primary = Color(named: "primary")
    public static let secondary = Color(named: "secondary")
    public static let accentColor = Color(named: "accentColor")
    public static let clear = Color(named: "clear")
    public static let black = Color(named: "black")
    public static let white = Color(named: "white")
    public static let gray = Color(named: "gray")
    public static let red = Color(named: "red")
    public static let orange = Color(named: "orange")
    public static let yellow = Color(named: "yellow")
    public static let green = Color(named: "green")
    public static let mint = Color(named: "mint")
    public static let teal = Color(named: "teal")
    public static let cyan = Color(named: "cyan")
    public static let blue = Color(named: "blue")
    public static let indigo = Color(named: "indigo")
    public static let purple = Color(named: "purple")
    public static let pink = Color(named: "pink")
    public static let brown = Color(named: "brown")

    /// The same color with a different opacity.
    public func opacity(_ opacity: Double) -> Color {
        switch storage {
        case .rgba(let value):
            let alpha = UInt32(Swift.max(0, Swift.min(255, (opacity * 255).rounded())))
            return Color(storage: .rgba(alpha << 24 | (value & 0x00FF_FFFF)))
        case .named(let name, _):
            return Color(storage: .named(name, opacity: opacity))
        }
    }

    init(storage: Storage) {
        self.storage = storage
    }

    var propValue: PropValue {
        switch storage {
        case .named(let name, let opacity):
            return opacity == 1 ? .string(name) : .array([.string(name), .double(opacity)])
        case .rgba(let value): return .int(Int(value))
        }
    }
}

/// A font: a text style the platform scales, or a fixed size.
public struct Font: Equatable, Sendable {

    public enum Weight: String, Sendable {
        case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
    }

    public enum Design: String, Sendable {
        case `default`, serif, rounded, monospaced
    }

    var props: [String: PropValue]

    init(_ props: [String: PropValue]) {
        self.props = props
    }

    static func style(_ name: String) -> Font {
        Font(["style": .string(name)])
    }

    public static let largeTitle = style("largeTitle")
    public static let title = style("title")
    public static let title2 = style("title2")
    public static let title3 = style("title3")
    public static let headline = style("headline")
    public static let subheadline = style("subheadline")
    public static let body = style("body")
    public static let callout = style("callout")
    public static let footnote = style("footnote")
    public static let caption = style("caption")
    public static let caption2 = style("caption2")

    public static func system(size: Double, weight: Weight = .regular, design: Design = .default) -> Font {
        Font(["size": .double(size), "weight": .string(weight.rawValue), "design": .string(design.rawValue)])
    }

    public func weight(_ weight: Weight) -> Font {
        var font = self
        font.props["weight"] = .string(weight.rawValue)
        return font
    }

    public func bold() -> Font {
        weight(.bold)
    }

    public func italic() -> Font {
        var font = self
        font.props["italic"] = .bool(true)
        return font
    }
}
