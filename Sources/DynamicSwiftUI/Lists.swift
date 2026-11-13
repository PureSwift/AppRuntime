import DynamicUI

/// A lazy container's node: `count` rows, fetched by the host with
/// `RendererDelegate.row` for the ones it shows. `revision` changes with
/// every update, so the host re-fetches its visible rows.
func lazyNode<Data: RandomAccessCollection, Content: View>(
    _ type: String,
    props: [String: PropValue] = [:],
    _ forEach: ForEach<Data, Content>,
    context: RenderContext
) -> RenderNode {
    let graph = context.graph
    let id = graph.nextNodeID()
    let listScope = graph.currentScopeKey
    let count = forEach.data.count
    graph.lazyList(id, count: count) { index in
        let element = forEach.element(index)
        var nodes: [RenderNode] = []
        graph.rowScope(listScope: listScope, identity: forEach.identity(element)) {
            forEach.content(element)._render(into: &nodes, context: context)
        }
        if nodes.count == 1 {
            return nodes[0]
        }
        let rowID = ViewGraph.mix(id ^ 0x524f_5700_0000_0000, forEach.identity(element))
        return RenderNode("VStack", id: rowID, props: [
            "alignment": "leading", "spacing": .double(defaultSpacing),
        ], children: nodes)
    }
    var props = props
    props["revision"] = .int(graph.currentRevision)
    return RenderNode(type, id: id, props: props, count: count)
}

/// Rows in a platform list.
///
/// `List(data) { row }` is lazy: the host asks only for the rows it shows.
/// `List { … }` renders its rows eagerly.
public struct List<Content: View>: View {

    enum Storage {
        case eager(Content)
        case lazy((RenderContext) -> RenderNode)
    }

    let storage: Storage

    public init(@ViewBuilder content: () -> Content) {
        self.storage = .eager(content())
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        switch storage {
        case .eager(let content):
            let id = context.graph.nextNodeID()
            nodes.append(RenderNode("List", id: id, children: context.children(content)))
        case .lazy(let make):
            nodes.append(make(context))
        }
    }
}

extension List {

    public init<Data: RandomAccessCollection, Row: View>(
        _ data: Data,
        @ViewBuilder rowContent: @escaping (Data.Element) -> Row
    ) where Content == ForEach<Data, Row>, Data.Element: Identifiable {
        let forEach = ForEach(data, content: rowContent)
        self.storage = .lazy { context in lazyNode("List", forEach, context: context) }
    }

    public init<Data: RandomAccessCollection, ID: Hashable, Row: View>(
        _ data: Data,
        id: @escaping (Data.Element) -> ID,
        @ViewBuilder rowContent: @escaping (Data.Element) -> Row
    ) where Content == ForEach<Data, Row> {
        let forEach = ForEach(data, id: id, content: rowContent)
        self.storage = .lazy { context in lazyNode("List", forEach, context: context) }
    }

    public init<Row: View>(
        _ data: Range<Int>,
        @ViewBuilder rowContent: @escaping (Int) -> Row
    ) where Content == ForEach<Range<Int>, Row> {
        let forEach = ForEach(data, content: rowContent)
        self.storage = .lazy { context in lazyNode("List", forEach, context: context) }
    }
}

/// Controls grouped for data entry: a `Form` node, whose children are its
/// rows and sections.
public struct Form<Content: View>: View {

    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let id = context.graph.nextNodeID()
        nodes.append(RenderNode("Form", id: id, children: context.children(content)))
    }
}

/// A group of rows with an optional header and footer.
public struct Section<Content: View>: View {

    let header: String?

    let footer: String?

    let content: Content

    public init(_ header: String, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = nil
        self.content = content()
    }

    public init(header: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        var props: [String: PropValue] = [:]
        if let header { props["header"] = .string(header) }
        if let footer { props["footer"] = .string(footer) }
        let id = context.graph.nextNodeID()
        nodes.append(RenderNode("Section", id: id, props: props, children: context.children(content)))
    }
}

/// A vertical stack that renders only the rows the host shows, when its
/// content is a `ForEach`; otherwise it renders everything, like `VStack`.
public struct LazyVStack<Content: View>: View {

    let make: (RenderContext) -> RenderNode

    /// Renders everything; content that's a `ForEach` takes the lazy initializer.
    @_disfavoredOverload
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        let content = content()
        let props: [String: PropValue] = ["alignment": .string(alignment.rawValue), "spacing": .double(spacing ?? defaultSpacing)]
        self.make = { context in
            RenderNode("LazyVStack", id: context.graph.nextNodeID(), props: props, children: context.children(content))
        }
    }

    public init<Data: RandomAccessCollection, Row: View>(
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> ForEach<Data, Row>
    ) where Content == ForEach<Data, Row> {
        let forEach = content()
        let props: [String: PropValue] = ["alignment": .string(alignment.rawValue), "spacing": .double(spacing ?? defaultSpacing)]
        self.make = { context in lazyNode("LazyVStack", props: props, forEach, context: context) }
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        nodes.append(make(context))
    }
}

/// The horizontal counterpart of `LazyVStack`.
public struct LazyHStack<Content: View>: View {

    let make: (RenderContext) -> RenderNode

    /// Renders everything; content that's a `ForEach` takes the lazy initializer.
    @_disfavoredOverload
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        let content = content()
        let props: [String: PropValue] = ["alignment": .string(alignment.rawValue), "spacing": .double(spacing ?? defaultSpacing)]
        self.make = { context in
            RenderNode("LazyHStack", id: context.graph.nextNodeID(), props: props, children: context.children(content))
        }
    }

    public init<Data: RandomAccessCollection, Row: View>(
        alignment: VerticalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> ForEach<Data, Row>
    ) where Content == ForEach<Data, Row> {
        let forEach = content()
        let props: [String: PropValue] = ["alignment": .string(alignment.rawValue), "spacing": .double(spacing ?? defaultSpacing)]
        self.make = { context in lazyNode("LazyHStack", props: props, forEach, context: context) }
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        nodes.append(make(context))
    }
}
