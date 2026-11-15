import DynamicUI

/// A shape that fills the space offered: `Rectangle`, `RoundedRectangle`,
/// `Circle`, `Ellipse`, `Capsule`.
///
/// A `Shape` node has its `shape` (`rectangle`, `roundedRectangle`,
/// `circle`, `ellipse`, `capsule`) and, for a rounded rectangle,
/// `cornerRadius`. Unstyled, it's filled with the foreground color;
/// `fill(_:)` sets `fill`, and `stroke(_:lineWidth:)` sets `stroke` and
/// `lineWidth` instead.
public protocol Shape: View where Body == Never {
    var _shapeProps: [String: PropValue] { get }
}

extension Shape {

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        nodes.append(context.node("Shape", props: _shapeProps))
    }

    /// The shape filled with `color`.
    public func fill(_ color: Color) -> _StyledShape<Self> {
        _StyledShape(shape: self, style: ["fill": color.propValue])
    }

    /// The shape's outline, `lineWidth` wide, in `color`.
    public func stroke(_ color: Color, lineWidth: CGFloat = 1) -> _StyledShape<Self> {
        _StyledShape(shape: self, style: ["stroke": color.propValue, "lineWidth": .double(lineWidth)])
    }
}

public struct _StyledShape<S: Shape>: View {

    let shape: S

    let style: [String: PropValue]

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        var props = shape._shapeProps
        for (key, value) in style {
            props[key] = value
        }
        nodes.append(context.node("Shape", props: props))
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
