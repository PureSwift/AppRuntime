import DynamicUI
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// An outline: lines, quadratic and cubic curves. A value, as SwiftUI's
/// is. Rectangles, ellipses and arcs are added as curves, and everything
/// it's asked is answered here, without the host.
///
/// ```swift
/// var path = Path()
/// path.move(to: Point(x: rect.midX, y: rect.minY))
/// path.addLine(to: Point(x: rect.maxX, y: rect.maxY))
/// path.addLine(to: Point(x: rect.minX, y: rect.maxY))
/// path.closeSubpath()
/// ```
public struct Path: Equatable, Sendable {

    public enum Element: Equatable, Sendable {
        case move(to: Point)
        case line(to: Point)
        case quadCurve(to: Point, control: Point)
        case curve(to: Point, control1: Point, control2: Point)
        case closeSubpath
    }

    public private(set) var elements: [Element] = []

    /// Where the last subpath began, for `closeSubpath`.
    private var start: Point?

    public init() { }

    public init(_ rect: Rect) {
        addRect(rect)
    }

    public init(roundedRect rect: Rect, cornerRadius: Double) {
        addRoundedRect(in: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius)
    }

    public init(ellipseIn rect: Rect) {
        addEllipse(in: rect)
    }

    /// Built by a closure, as SwiftUI's `Path { path in … }`.
    public init(_ build: (inout Path) -> Void) {
        build(&self)
    }

    public var isEmpty: Bool {
        elements.isEmpty
    }

    /// The end of the last element; `nil` for an empty path.
    public var currentPoint: Point? {
        guard let last = elements.last else { return nil }
        switch last {
        case .move(let point), .line(let point), .quadCurve(let point, _), .curve(let point, _, _):
            return point
        case .closeSubpath:
            return start
        }
    }

    // MARK: Building

    public mutating func move(to point: Point) {
        elements.append(.move(to: point))
        start = point
    }

    /// From the current point; a move first, on an empty path.
    public mutating func addLine(to point: Point) {
        guard currentPoint != nil else { return move(to: point) }
        elements.append(.line(to: point))
    }

    public mutating func addLines(_ points: [Point]) {
        guard let first = points.first else { return }
        move(to: first)
        for point in points.dropFirst() {
            addLine(to: point)
        }
    }

    public mutating func addQuadCurve(to point: Point, control: Point) {
        guard currentPoint != nil else { return move(to: point) }
        elements.append(.quadCurve(to: point, control: control))
    }

    public mutating func addCurve(to point: Point, control1: Point, control2: Point) {
        guard currentPoint != nil else { return move(to: point) }
        elements.append(.curve(to: point, control1: control1, control2: control2))
    }

    public mutating func closeSubpath() {
        guard currentPoint != nil, elements.last != .closeSubpath else { return }
        elements.append(.closeSubpath)
    }

    public mutating func addRect(_ rect: Rect) {
        guard !rect.isNull else { return }
        let rect = rect.standardized
        move(to: Point(x: rect.minX, y: rect.minY))
        addLine(to: Point(x: rect.maxX, y: rect.minY))
        addLine(to: Point(x: rect.maxX, y: rect.maxY))
        addLine(to: Point(x: rect.minX, y: rect.maxY))
        closeSubpath()
    }

    public mutating func addRects(_ rects: [Rect]) {
        for rect in rects {
            addRect(rect)
        }
    }

    /// Corners rounded by quarter ellipses, no larger than half each side.
    public mutating func addRoundedRect(in rect: Rect, cornerWidth: Double, cornerHeight: Double) {
        guard !rect.isNull else { return }
        let rect = rect.standardized
        let rx = Swift.min(Swift.max(cornerWidth, 0), rect.width / 2)
        let ry = Swift.min(Swift.max(cornerHeight, 0), rect.height / 2)
        guard rx > 0, ry > 0 else { return addRect(rect) }
        let k = Self.kappa
        move(to: Point(x: rect.minX + rx, y: rect.minY))
        addLine(to: Point(x: rect.maxX - rx, y: rect.minY))
        addCurve(to: Point(x: rect.maxX, y: rect.minY + ry),
                 control1: Point(x: rect.maxX - rx + rx * k, y: rect.minY),
                 control2: Point(x: rect.maxX, y: rect.minY + ry - ry * k))
        addLine(to: Point(x: rect.maxX, y: rect.maxY - ry))
        addCurve(to: Point(x: rect.maxX - rx, y: rect.maxY),
                 control1: Point(x: rect.maxX, y: rect.maxY - ry + ry * k),
                 control2: Point(x: rect.maxX - rx + rx * k, y: rect.maxY))
        addLine(to: Point(x: rect.minX + rx, y: rect.maxY))
        addCurve(to: Point(x: rect.minX, y: rect.maxY - ry),
                 control1: Point(x: rect.minX + rx - rx * k, y: rect.maxY),
                 control2: Point(x: rect.minX, y: rect.maxY - ry + ry * k))
        addLine(to: Point(x: rect.minX, y: rect.minY + ry))
        addCurve(to: Point(x: rect.minX + rx, y: rect.minY),
                 control1: Point(x: rect.minX, y: rect.minY + ry - ry * k),
                 control2: Point(x: rect.minX + rx - rx * k, y: rect.minY))
        closeSubpath()
    }

    /// Four cubic curves, from the right-hand point, clockwise on screen.
    public mutating func addEllipse(in rect: Rect) {
        guard !rect.isNull else { return }
        let rect = rect.standardized
        let rx = rect.width / 2
        let ry = rect.height / 2
        let cx = rect.midX
        let cy = rect.midY
        let k = Self.kappa
        move(to: Point(x: cx + rx, y: cy))
        addCurve(to: Point(x: cx, y: cy + ry), control1: Point(x: cx + rx, y: cy + ry * k), control2: Point(x: cx + rx * k, y: cy + ry))
        addCurve(to: Point(x: cx - rx, y: cy), control1: Point(x: cx - rx * k, y: cy + ry), control2: Point(x: cx - rx, y: cy + ry * k))
        addCurve(to: Point(x: cx, y: cy - ry), control1: Point(x: cx - rx, y: cy - ry * k), control2: Point(x: cx - rx * k, y: cy - ry))
        addCurve(to: Point(x: cx + rx, y: cy), control1: Point(x: cx + rx * k, y: cy - ry), control2: Point(x: cx + rx, y: cy - ry * k))
        closeSubpath()
    }

    /// An arc of a circle, as CoreGraphics draws it: a line from the current
    /// point to its start, then the arc. With y down, `clockwise: true`
    /// turns counterclockwise on screen, as in a flipped `CGContext` and in
    /// SwiftUI's `Path`.
    public mutating func addArc(center: Point, radius: Double, startAngle: Double, endAngle: Double, clockwise: Bool, transform: AffineTransform = .identity) {
        guard radius >= 0 else { return }
        let twoPi = 2 * Double.pi
        // How far it sweeps, in the direction asked: positive is towards
        // increasing angles, which is clockwise on screen.
        var sweep = endAngle - startAngle
        if clockwise {
            // Decreasing angles.
            if sweep > 0 {
                sweep -= twoPi * (Double(Int64(sweep / twoPi)) + 1)
            }
            if sweep < -twoPi { sweep = -twoPi }
        } else {
            if sweep < 0 {
                sweep += twoPi * (Double(Int64(-sweep / twoPi)) + 1)
            }
            if sweep > twoPi { sweep = twoPi }
        }
        func point(_ angle: Double) -> Point {
            Point(x: center.x + radius * _Math.cos(angle), y: center.y + radius * _Math.sin(angle)).applying(transform)
        }
        let first = point(startAngle)
        if currentPoint == nil {
            move(to: first)
        } else {
            addLine(to: first)
        }
        // A cubic per quarter turn or less.
        // Rounded up through an integer: `rounded(.up)` can be a libm call.
        let quarters = Swift.abs(sweep) / (Double.pi / 2)
        var pieces = Int(quarters)
        if Double(pieces) < quarters { pieces += 1 }
        pieces = Swift.max(pieces, 1)
        let step = sweep / Double(pieces)
        let handle = 4.0 / 3.0 * _Math.sin(step / 4) / _Math.cos(step / 4) * radius
        var angle = startAngle
        for _ in 0..<pieces {
            let next = angle + step
            let c1 = Point(x: center.x + radius * _Math.cos(angle) - handle * _Math.sin(angle),
                           y: center.y + radius * _Math.sin(angle) + handle * _Math.cos(angle)).applying(transform)
            let c2 = Point(x: center.x + radius * _Math.cos(next) + handle * _Math.sin(next),
                           y: center.y + radius * _Math.sin(next) - handle * _Math.cos(next)).applying(transform)
            addCurve(to: point(next), control1: c1, control2: c2)
            angle = next
        }
    }

    /// A rounded corner between the line to `tangent1End` and the line on
    /// to `tangent2End`, as CoreGraphics' `addArc(tangent1End:…)`.
    public mutating func addArc(tangent1End: Point, tangent2End: Point, radius: Double) {
        guard let current = currentPoint else { return move(to: tangent1End) }
        let v1 = Vector(dx: current.x - tangent1End.x, dy: current.y - tangent1End.y)
        let v2 = Vector(dx: tangent2End.x - tangent1End.x, dy: tangent2End.y - tangent1End.y)
        let l1 = (v1.dx * v1.dx + v1.dy * v1.dy).squareRoot()
        let l2 = (v2.dx * v2.dx + v2.dy * v2.dy).squareRoot()
        let cross = v1.dx * v2.dy - v1.dy * v2.dx
        guard radius > 0, l1 > 0, l2 > 0, cross != 0 else { return addLine(to: tangent1End) }
        let u1 = Vector(dx: v1.dx / l1, dy: v1.dy / l1)
        let u2 = Vector(dx: v2.dx / l2, dy: v2.dy / l2)
        // Half the angle between the two lines.
        let cosine = Swift.max(-1, Swift.min(1, u1.dx * u2.dx + u1.dy * u2.dy))
        let half = _Math.atan2((1 - cosine * cosine).squareRoot(), cosine) / 2
        let distance = radius / (_Math.sin(half) / _Math.cos(half))
        let p1 = Point(x: tangent1End.x + u1.dx * distance, y: tangent1End.y + u1.dy * distance)
        let p2 = Point(x: tangent1End.x + u2.dx * distance, y: tangent1End.y + u2.dy * distance)
        // The center is along the bisector, `radius / sin(half)` away.
        let bisector = Vector(dx: u1.dx + u2.dx, dy: u1.dy + u2.dy)
        let length = (bisector.dx * bisector.dx + bisector.dy * bisector.dy).squareRoot()
        let reach = radius / _Math.sin(half)
        let center = Point(x: tangent1End.x + bisector.dx / length * reach, y: tangent1End.y + bisector.dy / length * reach)
        let start = _Math.atan2(p1.y - center.y, p1.x - center.x)
        let end = _Math.atan2(p2.y - center.y, p2.x - center.x)
        addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: cross > 0)
    }

    public mutating func addPath(_ path: Path, transform: AffineTransform = .identity) {
        for element in path.applying(transform).elements {
            switch element {
            case .move(let point): move(to: point)
            case .line(let point): addLine(to: point)
            case .quadCurve(let point, let control): addQuadCurve(to: point, control: control)
            case .curve(let point, let c1, let c2): addCurve(to: point, control1: c1, control2: c2)
            case .closeSubpath: closeSubpath()
            }
        }
    }

    // MARK: Asking

    /// Every point transformed.
    public func applying(_ transform: AffineTransform) -> Path {
        guard !transform.isIdentity else { return self }
        var path = Path()
        path.elements = elements.map { element in
            switch element {
            case .move(let p): .move(to: p.applying(transform))
            case .line(let p): .line(to: p.applying(transform))
            case .quadCurve(let p, let c): .quadCurve(to: p.applying(transform), control: c.applying(transform))
            case .curve(let p, let c1, let c2): .curve(to: p.applying(transform), control1: c1.applying(transform), control2: c2.applying(transform))
            case .closeSubpath: .closeSubpath
            }
        }
        path.start = start?.applying(transform)
        return path
    }

    /// The smallest rect holding every point and control point, as
    /// CoreGraphics' `boundingBox`. `Rect.null` for an empty path.
    public var boundingRect: Rect {
        var bounds = Rect.null
        func include(_ point: Point) {
            bounds = bounds.union(Rect(origin: point, size: .zero))
        }
        for element in elements {
            switch element {
            case .move(let p), .line(let p): include(p)
            case .quadCurve(let p, let c): include(p); include(c)
            case .curve(let p, let c1, let c2): include(p); include(c1); include(c2)
            case .closeSubpath: break
            }
        }
        return bounds
    }

    /// Whether `point` is inside, by `rule`. Curves are followed in short
    /// lines, which is within a hundredth of a point for any curve a view
    /// draws.
    public func contains(_ point: Point, eoFill: Bool = false) -> Bool {
        contains(point, using: eoFill ? .evenOdd : .winding)
    }

    public func contains(_ point: Point, using rule: FillRule) -> Bool {
        var winding = 0
        var crossings = 0
        for (a, b) in segments() {
            // A line from `point` to the right, against each edge.
            guard (a.y <= point.y) != (b.y <= point.y) else { continue }
            let x = a.x + (point.y - a.y) / (b.y - a.y) * (b.x - a.x)
            guard x > point.x else { continue }
            crossings += 1
            winding += b.y > a.y ? 1 : -1
        }
        return rule == .winding ? winding != 0 : crossings % 2 == 1
    }

    /// The path as straight edges, each subpath closed.
    func segments() -> [(Point, Point)] {
        var edges: [(Point, Point)] = []
        var current = Point.zero
        var first = Point.zero
        var open = false
        func line(to point: Point) {
            edges.append((current, point))
            current = point
        }
        for element in elements {
            switch element {
            case .move(let p):
                if open, current != first { edges.append((current, first)) }
                current = p
                first = p
                open = true
            case .line(let p):
                line(to: p)
            case .quadCurve(let p, let c):
                let from = current
                for step in 1...16 {
                    let t = Double(step) / 16
                    let u = 1 - t
                    line(to: Point(x: u * u * from.x + 2 * u * t * c.x + t * t * p.x,
                                   y: u * u * from.y + 2 * u * t * c.y + t * t * p.y))
                }
            case .curve(let p, let c1, let c2):
                let from = current
                for step in 1...24 {
                    let t = Double(step) / 24
                    let u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    line(to: Point(x: a * from.x + b * c1.x + c * c2.x + d * p.x,
                                   y: a * from.y + b * c1.y + c * c2.y + d * p.y))
                }
            case .closeSubpath:
                if current != first { edges.append((current, first)) }
                current = first
                open = false
            }
        }
        if open, current != first { edges.append((current, first)) }
        return edges
    }

    /// A quarter circle's control handle, as a fraction of its radius.
    static let kappa = 0.5522847498307936
}
