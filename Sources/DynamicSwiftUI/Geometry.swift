/// Points, vectors, rectangles and affine transforms, in points: what
/// SwiftUI's API and a drawing are spelled with. CoreGraphics' names
/// without the prefix, and its `CG` spellings as aliases.

/// A position, in points.
public struct Point: Hashable, Sendable {

    public var x: Double

    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)

    public func applying(_ transform: AffineTransform) -> Point {
        Point(
            x: transform.a * x + transform.c * y + transform.tx,
            y: transform.b * x + transform.d * y + transform.ty
        )
    }
}

/// A distance on each axis.
public struct Vector: Hashable, Sendable {

    public var dx: Double

    public var dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }

    public static let zero = Vector(dx: 0, dy: 0)
}

extension Size {

    /// Scaled and rotated, but not moved.
    public func applying(_ transform: AffineTransform) -> Size {
        Size(width: transform.a * width + transform.c * height, height: transform.b * width + transform.d * height)
    }
}

/// An origin and a size. A negative width or height is measured back from
/// the origin; `standardized` turns it around.
public struct Rect: Hashable, Sendable {

    public var origin: Point

    public var size: Size

    public init(origin: Point, size: Size) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: Point(x: x, y: y), size: Size(width: width, height: height))
    }

    /// At the origin.
    public init(size: Size) {
        self.init(origin: .zero, size: size)
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    /// The null rect, as CoreGraphics has it: what `intersection` of two
    /// rects that don't meet gives.
    public static let null = Rect(x: .infinity, y: .infinity, width: 0, height: 0)

    public var isNull: Bool {
        origin.x == .infinity || origin.y == .infinity
    }

    public var width: Double { Swift.abs(size.width) }

    public var height: Double { Swift.abs(size.height) }

    public var minX: Double { Swift.min(origin.x, origin.x + size.width) }

    public var maxX: Double { Swift.max(origin.x, origin.x + size.width) }

    public var midX: Double { origin.x + size.width / 2 }

    public var minY: Double { Swift.min(origin.y, origin.y + size.height) }

    public var maxY: Double { Swift.max(origin.y, origin.y + size.height) }

    public var midY: Double { origin.y + size.height / 2 }

    /// The middle. Not CoreGraphics', and what a drawing asks for most.
    public var center: Point { Point(x: midX, y: midY) }

    public var isEmpty: Bool {
        isNull || size.width == 0 || size.height == 0
    }

    public var standardized: Rect {
        Rect(x: minX, y: minY, width: width, height: height)
    }

    public func insetBy(dx: Double, dy: Double) -> Rect {
        let rect = standardized
        let inset = Rect(x: rect.minX + dx, y: rect.minY + dy, width: rect.width - 2 * dx, height: rect.height - 2 * dy)
        return inset.size.width < 0 || inset.size.height < 0 ? .null : inset
    }

    public func offsetBy(dx: Double, dy: Double) -> Rect {
        Rect(x: origin.x + dx, y: origin.y + dy, width: size.width, height: size.height)
    }

    public func contains(_ point: Point) -> Bool {
        !isNull && point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    public func contains(_ rect: Rect) -> Bool {
        union(rect) == standardized
    }

    public func intersects(_ rect: Rect) -> Bool {
        !intersection(rect).isNull
    }

    public func union(_ rect: Rect) -> Rect {
        if isNull { return rect.standardized }
        if rect.isNull { return standardized }
        let minX = Swift.min(self.minX, rect.minX)
        let minY = Swift.min(self.minY, rect.minY)
        return Rect(x: minX, y: minY, width: Swift.max(maxX, rect.maxX) - minX, height: Swift.max(maxY, rect.maxY) - minY)
    }

    public func intersection(_ rect: Rect) -> Rect {
        guard !isNull, !rect.isNull else { return .null }
        let minX = Swift.max(self.minX, rect.minX)
        let minY = Swift.max(self.minY, rect.minY)
        let maxX = Swift.min(self.maxX, rect.maxX)
        let maxY = Swift.min(self.maxY, rect.maxY)
        guard minX <= maxX, minY <= maxY else { return .null }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The smallest rect holding the transformed corners.
    public func applying(_ transform: AffineTransform) -> Rect {
        guard !isNull else { return self }
        let corners = [
            Point(x: minX, y: minY), Point(x: maxX, y: minY),
            Point(x: minX, y: maxY), Point(x: maxX, y: maxY),
        ].map { $0.applying(transform) }
        var bounds = Rect.null
        for corner in corners {
            bounds = bounds.union(Rect(origin: corner, size: .zero))
        }
        return bounds
    }
}

/// `x′ = a·x + c·y + tx`, `y′ = b·x + d·y + ty`, as CoreGraphics has it.
public struct AffineTransform: Hashable, Sendable {

    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public static let identity = AffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public init(translationX x: Double, y: Double) {
        self.init(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
    }

    public init(scaleX x: Double, y: Double) {
        self.init(a: x, b: 0, c: 0, d: y, tx: 0, ty: 0)
    }

    /// Radians. With y down, a positive angle turns clockwise on screen.
    public init(rotationAngle angle: Double) {
        let sine = _Math.sin(angle)
        let cosine = _Math.cos(angle)
        self.init(a: cosine, b: sine, c: -sine, d: cosine, tx: 0, ty: 0)
    }

    public var isIdentity: Bool {
        self == .identity
    }

    /// `self`, then `other`.
    public func concatenating(_ other: AffineTransform) -> AffineTransform {
        AffineTransform(
            a: a * other.a + b * other.c,
            b: a * other.b + b * other.d,
            c: c * other.a + d * other.c,
            d: c * other.b + d * other.d,
            tx: tx * other.a + ty * other.c + other.tx,
            ty: tx * other.b + ty * other.d + other.ty
        )
    }

    /// Moves, then applies `self`, as CoreGraphics' `translatedBy` does.
    public func translatedBy(x: Double, y: Double) -> AffineTransform {
        AffineTransform(translationX: x, y: y).concatenating(self)
    }

    public func scaledBy(x: Double, y: Double) -> AffineTransform {
        AffineTransform(scaleX: x, y: y).concatenating(self)
    }

    public func rotated(by angle: Double) -> AffineTransform {
        AffineTransform(rotationAngle: angle).concatenating(self)
    }

    /// `self` unchanged when it can't be inverted, as CoreGraphics does.
    public func inverted() -> AffineTransform {
        let determinant = a * d - b * c
        guard determinant != 0 else { return self }
        return AffineTransform(
            a: d / determinant,
            b: -b / determinant,
            c: -c / determinant,
            d: a / determinant,
            tx: (c * ty - d * tx) / determinant,
            ty: (b * tx - a * ty) / determinant
        )
    }
}

public typealias CGPoint = Point
public typealias CGVector = Vector
public typealias CGRect = Rect
public typealias CGAffineTransform = AffineTransform

/// Sine, cosine and arctangent in Swift: a guest can't call libm (§7.5).
/// Within 1e-12 of libm's over the ranges a drawing uses.
public enum _Math {

    static let pi = Double.pi

    /// Radians.
    public static func sin(_ x: Double) -> Double {
        guard x.isFinite, Swift.abs(x) < 1e15 else { return .nan }
        // To -π…π, then to -π/2…π/2, where the series is short. Rounded
        // through an integer: `rounded()` can be a libm call.
        let turns = x / (2 * pi)
        var r = x - 2 * pi * Double(Int64(turns >= 0 ? turns + 0.5 : turns - 0.5))
        if r > pi / 2 {
            r = pi - r
        } else if r < -pi / 2 {
            r = -pi - r
        }
        let r2 = r * r
        var term = r
        var sum = r
        var n = 1.0
        for _ in 0..<10 {
            term *= -r2 / ((n + 1) * (n + 2))
            sum += term
            n += 2
        }
        return sum
    }

    public static func cos(_ x: Double) -> Double {
        sin(x + pi / 2)
    }

    public static func atan(_ x: Double) -> Double {
        guard !x.isNaN else { return .nan }
        if x < 0 { return -atan(-x) }
        if x > 1 { return pi / 2 - atan(1 / x) }
        // Above tan(π/12), shift by π/6, so the series converges fast.
        let root3 = 1.7320508075688772
        if x > 0.2679491924311227 {
            return pi / 6 + atan((x * root3 - 1) / (root3 + x))
        }
        let x2 = x * x
        var term = x
        var sum = x
        var n = 1.0
        for _ in 0..<12 {
            term *= -x2
            n += 2
            sum += term / n
        }
        return sum
    }

    public static func atan2(_ y: Double, _ x: Double) -> Double {
        if x > 0 { return atan(y / x) }
        if x < 0 { return y >= 0 ? atan(y / x) + pi : atan(y / x) - pi }
        if y > 0 { return pi / 2 }
        if y < 0 { return -pi / 2 }
        return 0
    }
}
