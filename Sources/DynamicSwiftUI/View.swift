import DynamicUI

/// A piece of user interface: SwiftUI's `View`.
///
/// Composed views implement `body`. Primitive views (`Text`, `VStack`, …)
/// implement `_render` instead, and emit render IR.
public protocol View {

    associatedtype Body: View

    @ViewBuilder var body: Body { get }

    /// Emits this view's nodes. Composed views use the default, which
    /// evaluates `body` in the view's own scope.
    func _render(into nodes: inout [RenderNode], context: RenderContext)
}

extension View {

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let graph = context.graph
        graph.scoped {
            graph.pushContext(context)
            defer { graph.popContext() }
            body._render(into: &nodes, context: context)
        }
    }
}

/// Primitive views have no body.
extension Never: View {

    public var body: Never {
        fatalError("Never has no body")
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) { }
}

/// What a view inherits from its ancestors while it renders.
public struct RenderContext {

    /// Objects from `environmentObject(_:)` and `environment(_:)`, innermost last.
    var objects: [(type: ObjectIdentifier, object: AnyObject)] = []

    /// The navigation level being rendered, which collects its title and links.
    var navigation: NavigationLevel?

    /// What Return does in a text field, from `onSubmit(_:)`.
    var onSubmit: (() -> Void)?

    var graph: ViewGraph {
        ViewGraph.current!
    }

    init() { }

    /// The innermost object of type `T` in the environment.
    func object<T: AnyObject>(_ type: T.Type) -> T? {
        let id = ObjectIdentifier(type)
        guard let match = objects.last(where: { $0.type == id }) else { return nil }
        return unsafeDowncast(match.object, to: T.self)
    }
}

// MARK: - Structural views

public struct EmptyView: View {

    public init() { }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) { }
}

/// Two views one after the other; `ViewBuilder` nests these for longer blocks.
public struct TupleView<First: View, Second: View>: View {

    let first: First

    let second: Second

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        first._render(into: &nodes, context: context)
        second._render(into: &nodes, context: context)
    }
}

/// An `if` without `else`. Its content has its own scope, so the views after
/// it keep their identity whether or not it shows.
public struct OptionalView<Wrapped: View>: View {

    let content: Wrapped?

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        context.graph.scoped(identity: 1) {
            content?._render(into: &nodes, context: context)
        }
    }
}

/// An `if`/`else`. Each branch has its own identity.
public struct ConditionalView<TrueContent: View, FalseContent: View>: View {

    enum Storage {
        case first(TrueContent)
        case second(FalseContent)
    }

    let storage: Storage

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        switch storage {
        case .first(let content):
            context.graph.scoped(identity: 1) { content._render(into: &nodes, context: context) }
        case .second(let content):
            context.graph.scoped(identity: 2) { content._render(into: &nodes, context: context) }
        }
    }
}

/// A `for` loop in a `ViewBuilder`: elements keyed by position.
public struct ArrayView<Element: View>: View {

    let elements: [Element]

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        for (index, element) in elements.enumerated() {
            context.graph.scoped(identity: UInt64(index)) {
                element._render(into: &nodes, context: context)
            }
        }
    }
}

/// A type-erased view.
public struct AnyView: View {

    let render: (inout [RenderNode], RenderContext) -> Void

    public init<V: View>(_ view: V) {
        self.render = { nodes, context in view._render(into: &nodes, context: context) }
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        render(&nodes, context)
    }
}

/// Groups views without adding a node.
public struct Group<Content: View>: View {

    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        content._render(into: &nodes, context: context)
    }
}

// MARK: - ViewBuilder

@resultBuilder
public enum ViewBuilder {

    public static func buildBlock() -> EmptyView {
        EmptyView()
    }

    public static func buildExpression<Content: View>(_ content: Content) -> Content {
        content
    }

    public static func buildPartialBlock<Content: View>(first content: Content) -> Content {
        content
    }

    public static func buildPartialBlock<Accumulated: View, Next: View>(
        accumulated: Accumulated,
        next: Next
    ) -> TupleView<Accumulated, Next> {
        TupleView(first: accumulated, second: next)
    }

    public static func buildOptional<Content: View>(_ content: Content?) -> OptionalView<Content> {
        OptionalView(content: content)
    }

    public static func buildEither<TrueContent: View, FalseContent: View>(
        first content: TrueContent
    ) -> ConditionalView<TrueContent, FalseContent> {
        ConditionalView(storage: .first(content))
    }

    public static func buildEither<TrueContent: View, FalseContent: View>(
        second content: FalseContent
    ) -> ConditionalView<TrueContent, FalseContent> {
        ConditionalView(storage: .second(content))
    }

    public static func buildArray<Element: View>(_ elements: [Element]) -> ArrayView<Element> {
        ArrayView(elements: elements)
    }

    public static func buildLimitedAvailability<Content: View>(_ content: Content) -> AnyView {
        AnyView(content)
    }
}

// MARK: - ViewModifier

/// A reusable change to a view: SwiftUI's `ViewModifier`.
public protocol ViewModifier {

    associatedtype Body: View

    typealias Content = _ViewModifierContent

    @ViewBuilder func body(content: Content) -> Body
}

/// The view a `ViewModifier` modifies.
public struct _ViewModifierContent: View {

    let render: (inout [RenderNode], RenderContext) -> Void

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        render(&nodes, context)
    }
}

/// A view with a `ViewModifier` applied.
public struct ModifiedContent<Content: View, Modifier: ViewModifier>: View {

    let content: Content

    let modifier: Modifier

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let content = self.content
        let erased = _ViewModifierContent { nodes, context in content._render(into: &nodes, context: context) }
        let graph = context.graph
        graph.scoped {
            graph.pushContext(context)
            defer { graph.popContext() }
            modifier.body(content: erased)._render(into: &nodes, context: context)
        }
    }
}

extension View {

    public func modifier<Modifier: ViewModifier>(_ modifier: Modifier) -> ModifiedContent<Self, Modifier> {
        ModifiedContent(content: self, modifier: modifier)
    }
}
