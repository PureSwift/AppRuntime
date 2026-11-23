import DynamicRuntime
import DynamicUI
#if canImport(DynamicSwiftUI)
import DynamicSwiftUI
#else
import SwiftUI
#endif

/// A view the app draws, SwiftUI's `Canvas`: its closure gets a
/// `GraphicsContext` and the size the host gave it.
///
/// ```swift
/// Canvas { context, size in
///     context.fill(Path(ellipseIn: Rect(size: size)), with: .orange)
/// }
/// .frame(width: 120, height: 120)
/// ```
///
/// The closure runs when the host has a size for the canvas, and again when
/// the size, the scale or the user's text size changes, when the view is
/// updated, and when a value the closure read changes, as `body` does. A
/// change of appearance redraws the same recording with named colors
/// resolved again, without running it.
///
/// A `Canvas` node has `canvas`, the host's `DrawingCanvas`'s identifier.
public struct Canvas: View {

    let renderer: (GraphicsContext, Size) -> Void

    @State private var owner = CanvasOwner()

    /// `opaque`, `colorMode` and `rendersAsynchronously` are SwiftUI's, and
    /// ignored: the host decides.
    public init(opaque: Bool = false, rendersAsynchronously: Bool = false, renderer: @escaping (GraphicsContext, Size) -> Void) {
        self.renderer = renderer
    }

    public var body: some View {
        _RenderNodeView("Canvas", props: ["canvas": .int(Int(owner.show(renderer)))])
    }
}

/// A `Canvas`'s host canvas and what draws it, kept across updates.
final class CanvasOwner {

    private var renderer: ((GraphicsContext, Size) -> Void)?

    private var made: (any DrawingCanvas)?

    private var identifier: Int32 = 0

    private let receiver = CanvasReceiver()

    deinit {
        // The host may still hold the receiver until it destroys the canvas.
        receiver.owner = nil
    }

    /// Keeps the closure of this update, and asks the host to draw again if
    /// it had drawn. Returns the identifier the node carries.
    func show(_ renderer: @escaping (GraphicsContext, Size) -> Void) -> Int32 {
        self.renderer = renderer
        if let made {
            made.setNeedsDisplay()
            return identifier
        }
        receiver.owner = Unmanaged.passUnretained(self)
        let canvas = DrawingCanvasProxy.make(receiver)
        made = canvas
        identifier = canvas.identifier()
        return identifier
    }

    /// Kept while the host can replay the last drawing.
    private var context: GraphicsContext?

    func draw(width: Float, height: Float) -> [UInt8] {
        let context = GraphicsContext()
        let size = Size(width: Double(width), height: Double(height))
        let renderer = self.renderer
        let redraw = Redraw(owner: Unmanaged.passUnretained(self), receiver: receiver)
        withObservationTracking {
            renderer?(context, size)
        } onChange: {
            redraw.needed()
        }
        self.context = context
        return context.drawing
    }

    fileprivate func needsDisplay() {
        made?.setNeedsDisplay()
    }
}

/// What a canvas's observation calls when something its closure read
/// changes. The guest is single-threaded (§6.4).
private struct Redraw: @unchecked Sendable {

    let owner: Unmanaged<CanvasOwner>

    let receiver: CanvasReceiver

    func needed() {
        // The owner may have gone since; the receiver knows.
        guard receiver.owner != nil else { return }
        owner.takeUnretainedValue().needsDisplay()
    }
}

/// The delegate the host holds. It doesn't keep the owner alive: the owner
/// holds the host's canvas, which holds this, and the owner clears the
/// reference when it's released. Embedded Swift has no weak references.
final class CanvasReceiver: DrawingCanvasDelegate {

    var owner: Unmanaged<CanvasOwner>?

    func draw(_ canvas: any DrawingCanvas, width: Float, height: Float, scale: Float) -> [UInt8] {
        guard let owner = owner?.takeUnretainedValue() else { return DrawingWriter.header }
        return owner.draw(width: width, height: height)
    }
}

// MARK: - Shapes

/// An app's own shape is a canvas whose drawing is its path, filled or
/// stroked as the shape is styled.
extension Path: _ShapePath {

    public static func _render<S: Shape>(_ shape: S, style: _ShapeStyle, into nodes: inout [RenderNode], context: RenderContext) where S._Path == Path {
        Canvas { graphics, size in
            let path = shape.path(in: Rect(size: size))
            if let stroke = style.stroke {
                graphics.stroke(path, with: stroke, lineWidth: style.lineWidth)
            } else {
                // Unstyled is the foreground color.
                graphics.fill(path, with: style.fill ?? .primary)
            }
        }
        ._render(into: &nodes, context: context)
    }
}
