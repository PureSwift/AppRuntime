import DynamicUI
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// A view whose nodes get a modifier: the `ModifierNode` is appended to
/// each node its content produces, in order (§9.2). `register` runs per
/// node, for modifiers that also handle events or appearance.
public struct _ModifierView<Content: View>: View {

    let content: Content

    let modifier: ModifierNode?

    let register: ((RenderNode.ID, ViewGraph) -> Void)?

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        var produced: [RenderNode] = []
        content._render(into: &produced, context: context)
        let graph = context.graph
        for index in produced.indices {
            if let modifier {
                produced[index].modifiers.append(modifier)
            }
            register?(produced[index].id, graph)
        }
        nodes.append(contentsOf: produced)
    }
}

extension View {

    func modified(_ kind: String, _ args: [String: PropValue] = [:]) -> _ModifierView<Self> {
        _ModifierView(content: self, modifier: ModifierNode(kind, args), register: nil)
    }

    // MARK: Layout

    /// Pads the given edges; 16 points if `length` is `nil`.
    public func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> _ModifierView<Self> {
        let length = length ?? defaultPadding
        return modified("padding", [
            "top": .double(edges.contains(.top) ? length : 0),
            "leading": .double(edges.contains(.leading) ? length : 0),
            "bottom": .double(edges.contains(.bottom) ? length : 0),
            "trailing": .double(edges.contains(.trailing) ? length : 0),
        ])
    }

    public func padding(_ length: CGFloat) -> _ModifierView<Self> {
        padding(.all, length)
    }

    public func frame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> _ModifierView<Self> {
        var args = alignment.props
        if let width { args["width"] = .double(width) }
        if let height { args["height"] = .double(height) }
        return modified("frame", args)
    }

    /// `.infinity` as a maximum fills the space offered.
    public func frame(
        minWidth: CGFloat? = nil,
        idealWidth: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        minHeight: CGFloat? = nil,
        idealHeight: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        alignment: Alignment = .center
    ) -> _ModifierView<Self> {
        var args = alignment.props
        if let minWidth { args["minWidth"] = .double(minWidth) }
        if let idealWidth { args["idealWidth"] = .double(idealWidth) }
        if let maxWidth { args["maxWidth"] = .double(maxWidth) }
        if let minHeight { args["minHeight"] = .double(minHeight) }
        if let idealHeight { args["idealHeight"] = .double(idealHeight) }
        if let maxHeight { args["maxHeight"] = .double(maxHeight) }
        return modified("frame", args)
    }

    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> _ModifierView<Self> {
        modified("offset", ["x": .double(x), "y": .double(y)])
    }

    // MARK: Appearance

    public func background(_ color: Color) -> _ModifierView<Self> {
        modified("background", ["color": color.propValue])
    }

    /// Inherited by descendants, like the other text styles.
    public func foregroundColor(_ color: Color?) -> _ModifierView<Self> {
        modified("foregroundColor", color.map { ["color": $0.propValue] } ?? [:])
    }

    public func foregroundStyle(_ color: Color) -> _ModifierView<Self> {
        foregroundColor(color)
    }

    public func tint(_ color: Color?) -> _ModifierView<Self> {
        modified("tint", color.map { ["color": $0.propValue] } ?? [:])
    }

    public func opacity(_ opacity: Double) -> _ModifierView<Self> {
        modified("opacity", ["value": .double(opacity)])
    }

    public func cornerRadius(_ radius: CGFloat) -> _ModifierView<Self> {
        modified("cornerRadius", ["radius": .double(radius)])
    }

    public func border(_ color: Color, width: CGFloat = 1) -> _ModifierView<Self> {
        modified("border", ["color": color.propValue, "width": .double(width)])
    }

    public func shadow(color: Color = Color(white: 0, opacity: 0.33), radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> _ModifierView<Self> {
        modified("shadow", ["color": color.propValue, "radius": .double(radius), "x": .double(x), "y": .double(y)])
    }

    // MARK: Text

    /// Inherited by descendants.
    public func font(_ font: Font?) -> _ModifierView<Self> {
        modified("font", font?.props ?? [:])
    }

    public func fontWeight(_ weight: Font.Weight?) -> _ModifierView<Self> {
        modified("fontWeight", weight.map { ["weight": .string($0.rawValue)] } ?? [:])
    }

    public func bold(_ isActive: Bool = true) -> _ModifierView<Self> {
        fontWeight(isActive ? .bold : nil)
    }

    public func italic(_ isActive: Bool = true) -> _ModifierView<Self> {
        modified("italic", ["value": .bool(isActive)])
    }

    public func lineLimit(_ lines: Int?) -> _ModifierView<Self> {
        modified("lineLimit", lines.map { ["lines": .int($0)] } ?? [:])
    }

    public func multilineTextAlignment(_ alignment: TextAlignment) -> _ModifierView<Self> {
        modified("multilineTextAlignment", ["alignment": .string(alignment.rawValue)])
    }

    // MARK: Interaction

    /// Inherited by descendants.
    public func disabled(_ disabled: Bool) -> _ModifierView<Self> {
        modified("disabled", ["value": .bool(disabled)])
    }

    public func onTapGesture(count: Int = 1, perform action: @escaping () -> Void) -> _ModifierView<Self> {
        _ModifierView(content: self, modifier: ModifierNode("onTapGesture", ["count": .int(count)])) { id, graph in
            graph.on(id, .tap) { _ in action() }
        }
    }

    /// What Return does in the text fields this view contains.
    public func onSubmit(_ action: @escaping () -> Void) -> _EnvironmentView<Self> {
        _EnvironmentView(content: self) { $0.onSubmit = action }
    }

    // MARK: Accessibility

    public func accessibilityLabel(_ label: String) -> _ModifierView<Self> {
        modified("accessibilityLabel", ["text": .string(label)])
    }

    public func accessibilityIdentifier(_ identifier: String) -> _ModifierView<Self> {
        modified("accessibilityIdentifier", ["identifier": .string(identifier)])
    }

    // MARK: Lifecycle

    /// Runs when the view's first node appears on screen. Guest-side: it
    /// doesn't go into the IR.
    public func onAppear(perform action: (() -> Void)? = nil) -> _ModifierView<Self> {
        _ModifierView(content: self, modifier: nil) { id, graph in
            graph.register(ViewGraph.Appearance(node: id, onAppear: action, onDisappear: nil))
        }
    }

    /// Runs when the view's first node leaves the screen.
    public func onDisappear(perform action: (() -> Void)? = nil) -> _ModifierView<Self> {
        _ModifierView(content: self, modifier: nil) { id, graph in
            graph.register(ViewGraph.Appearance(node: id, onAppear: nil, onDisappear: action))
        }
    }

    // MARK: Identity

    /// Gives the view an explicit identity: a new value is a new view, with
    /// fresh state.
    public func id<ID: Hashable>(_ id: ID) -> _IdentityView<Self> {
        _IdentityView(content: self, identity: UInt64(bitPattern: Int64(id.hashValue)))
    }
}

public struct _IdentityView<Content: View>: View {

    let content: Content

    let identity: UInt64

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        context.graph.scoped(identity: identity) {
            content._render(into: &nodes, context: context)
        }
    }
}

#if !EMBEDDED_NO_CONCURRENCY
/// The task a `.task` modifier runs while its view is on screen.
final class TaskHolder {
    var task: Task<Void, Never>?
}

extension View {

    /// Runs `action` while the view is on screen: started when it appears,
    /// cancelled when it disappears.
    public func task(_ action: @escaping @Sendable () async -> Void) -> _ModifierView<Self> {
        _ModifierView(content: self, modifier: nil) { id, graph in
            let holder = graph.stateBox { TaskHolder() }.value
            graph.register(ViewGraph.Appearance(
                node: id,
                onAppear: { holder.task = Task { await action() } },
                onDisappear: {
                    holder.task?.cancel()
                    holder.task = nil
                }
            ))
        }
    }
}
#endif
