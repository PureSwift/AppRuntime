import DynamicUI
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// Why drawing an image, or asking about one, failed.
public enum DrawingError: Int32, Error, Sendable {

    case unknown = 0

    /// Guest-side: the task waiting was cancelled. Hosts never send it.
    case cancelled = 1

    /// No such file, or not a file.
    case notFound = 2

    /// Not an image this host decodes, or a damaged one.
    case undecodable = 3

    /// More pixels than the host takes.
    case tooLarge = 4

    /// This host decodes no images.
    case unavailable = 5

    /// The app may not read the file: a document it let go of.
    case notPermitted = 6
}

// MARK: - Painting

/// How a stroke's open ends are drawn: CoreGraphics' `CGLineCap`.
public enum LineCap: UInt8, Sendable {
    case butt = 0
    case round = 1
    case square = 2
}

/// How a stroke's corners are drawn: CoreGraphics' `CGLineJoin`.
public enum LineJoin: UInt8, Sendable {
    case miter = 0
    case round = 1
    case bevel = 2
}

/// Which points are inside a path that crosses itself.
public enum FillRule: UInt8, Sendable {
    /// Inside where the path winds round a non-zero number of times.
    case winding = 0
    /// Inside where a line out crosses the path an odd number of times.
    case evenOdd = 1
}

/// What `drawPath(using:)` paints: CoreGraphics' `CGPathDrawingMode`.
public enum DrawingMode: Sendable {
    case fill
    case eoFill
    case stroke
    case fillStroke
    case eoFillStroke
}

/// How what's drawn mixes with what's there: CoreGraphics' modes, in its
/// order. A host that can't do one draws as `normal`.
public enum BlendMode: UInt8, Sendable {
    case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn
    case softLight, hardLight, difference, exclusion, hue, saturation, color, luminosity
    case clear, copy, sourceIn, sourceOut, sourceAtop, destinationOver, destinationIn, destinationOut
    case destinationAtop, xor, plusDarker, plusLighter
}

/// A stroke's width, ends, corners and dashes: SwiftUI's `StrokeStyle`.
public struct StrokeStyle: Equatable, Sendable {

    public var lineWidth: Double
    public var lineCap: LineCap
    public var lineJoin: LineJoin
    public var miterLimit: Double
    /// On, off, on…; empty is solid.
    public var dash: [Double]
    public var dashPhase: Double

    public init(lineWidth: Double = 1, lineCap: LineCap = .butt, lineJoin: LineJoin = .miter, miterLimit: Double = 10, dash: [Double] = [], dashPhase: Double = 0) {
        self.lineWidth = lineWidth
        self.lineCap = lineCap
        self.lineJoin = lineJoin
        self.miterLimit = miterLimit
        self.dash = dash
        self.dashPhase = dashPhase
    }
}

/// Colors at locations from 0 to 1.
public struct Gradient: Equatable, Sendable {

    public struct Stop: Equatable, Sendable {
        public var color: Color
        public var location: Double

        public init(color: Color, location: Double) {
            self.color = color
            self.location = location
        }
    }

    public var stops: [Stop]

    public init(stops: [Stop]) {
        self.stops = stops
    }

    /// Spaced evenly.
    public init(colors: [Color]) {
        let last = Swift.max(colors.count - 1, 1)
        self.stops = colors.indices.map { Stop(color: colors[$0], location: Double($0) / Double(last)) }
    }
}

/// Whether a gradient goes on past its ends: CoreGraphics'
/// `CGGradientDrawingOptions`.
public struct GradientOptions: OptionSet, Sendable {

    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let drawsBeforeStartLocation = GradientOptions(rawValue: 1)
    public static let drawsAfterEndLocation = GradientOptions(rawValue: 2)
}

/// A font's lines, in points.
public struct FontMetrics: Equatable, Sendable {
    public var ascent: Double
    public var descent: Double
    public var leading: Double
    public var capHeight: Double
    public var xHeight: Double

    public init(ascent: Double, descent: Double, leading: Double, capHeight: Double, xHeight: Double) {
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
        self.capHeight = capHeight
        self.xHeight = xHeight
    }

    /// From one line's top to the next's.
    public var lineHeight: Double {
        ascent + descent + leading
    }
}
