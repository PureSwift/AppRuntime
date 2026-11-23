import DynamicUI

/// A shape that fills the space offered: `Rectangle`, `RoundedRectangle`,
/// `Circle`, `Ellipse`, `Capsule`, or one of the app's own.
///
/// A `Shape` node has its `shape` (`rectangle`, `roundedRectangle`,
/// `circle`, `ellipse`, `capsule`) and, for a rounded rectangle,
/// `cornerRadius`. Unstyled, it's filled with the foreground color;
/// `fill(_:)` sets `fill`, and `stroke(_:lineWidth:)` sets `stroke` and
/// `lineWidth` instead.
///
/// An app's own shape gives its path, as in SwiftUI, with `DynamicDrawing`'s
/// `Path`, which draws it in a canvas the size the shape is given:
///
/// ```swift
/// struct Triangle: Shape {
///     func path(in rect: Rect) -> Path { … }
/// }
/// ```
public protocol Shape: View where Body == Never {

    /// What `path(in:)` gives: `DynamicDrawing`'s `Path` for an app's own
    /// shape. The built-in shapes are nodes, and have none.
    associatedtype _Path: _ShapePath = _NoShapePath

    /// The built-in shapes' node props; empty for an app's own.
    var _shapeProps: [String: PropValue] { get }

    func path(in rect: Rect) -> _Path
}

/// What a shape's path is, to the frontend: the module that draws it says
/// how it's rendered.
public protocol _ShapePath {

    static func _render<S: Shape>(_ shape: S, style: _ShapeStyle, into nodes: inout [RenderNode], context: RenderContext) where S._Path == Self
}

/// A built-in shape's: it's a node, and has no path here.
public struct _NoShapePath: _ShapePath {

    public static func _render<S: Shape>(_ shape: S, style: _ShapeStyle, into nodes: inout [RenderNode], context: RenderContext) where S._Path == _NoShapePath { }
}

/// How a shape is painted: filled, or stroked; neither is the foreground
/// color.
public struct _ShapeStyle: Equatable, Sendable {

    public var fill: Color?

    public var stroke: Color?

    public var lineWidth: Double

    public init(fill: Color? = nil, stroke: Color? = nil, lineWidth: Double = 1) {
        self.fill = fill
        self.stroke = stroke
        self.lineWidth = lineWidth
    }

    var props: [String: PropValue] {
        var props: [String: PropValue] = [:]
        if let fill { props["fill"] = fill.propValue }
        if let stroke {
            props["stroke"] = stroke.propValue
            props["lineWidth"] = .double(lineWidth)
        }
        return props
    }
}

extension Shape where _Path == _NoShapePath {

    public func path(in rect: Rect) -> _NoShapePath {
        _NoShapePath()
    }
}

extension Shape {

    public var _shapeProps: [String: PropValue] {
        [:]
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        render(_ShapeStyle(), into: &nodes, context: context)
    }

    func render(_ style: _ShapeStyle, into nodes: inout [RenderNode], context: RenderContext) {
        let props = _shapeProps
        guard !props.isEmpty else {
            _Path._render(self, style: style, into: &nodes, context: context)
            return
        }
        var styled = props
        for (key, value) in style.props {
            styled[key] = value
        }
        nodes.append(context.node("Shape", props: styled))
    }

    /// The shape filled with `color`.
    public func fill(_ color: Color) -> _StyledShape<Self> {
        _StyledShape(shape: self, style: _ShapeStyle(fill: color))
    }

    /// The shape's outline, `lineWidth` wide, in `color`.
    public func stroke(_ color: Color, lineWidth: CGFloat = 1) -> _StyledShape<Self> {
        _StyledShape(shape: self, style: _ShapeStyle(stroke: color, lineWidth: lineWidth))
    }
}

public struct _StyledShape<S: Shape>: View {

    let shape: S

    let style: _ShapeStyle

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        shape.render(style, into: &nodes, context: context)
    }
}

public struct Rectangle: Shape {
    public init() { }
    public var _shapeProps: [String: PropValue] { ["shape": "rectangle"] }
}

public struct RoundedRectangle: Shape {

    let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
    }

    public var _shapeProps: [String: PropValue] {
        ["shape": "roundedRectangle", "cornerRadius": .double(cornerRadius)]
    }
}

public struct Circle: Shape {
    public init() { }
    public var _shapeProps: [String: PropValue] { ["shape": "circle"] }
}

public struct Ellipse: Shape {
    public init() { }
    public var _shapeProps: [String: PropValue] { ["shape": "ellipse"] }
}

public struct Capsule: Shape {
    public init() { }
    public var _shapeProps: [String: PropValue] { ["shape": "capsule"] }
}
