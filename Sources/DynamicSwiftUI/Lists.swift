import DynamicUI

/// A lazy container's node: `count` rows, fetched by the host with
/// `RendererDelegate.row` for the ones it shows. `revision` changes with
/// every update, so the host re-fetches its visible rows.
func lazyNode<Data: RandomAccessCollection, Content: View>(
    _ type: String,
    props: [String: PropValue] = [:],
    _ forEach: ForEach<Data, Content>,
    context: RenderContext,
    tagged: Bool = false
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
        var row: RenderNode
        if nodes.count == 1 {
            row = nodes[0]
        } else {
            let rowID = ViewGraph.mix(id ^ 0x524f_5700_0000_0000, forEach.identity(element))
            row = RenderNode("VStack", id: rowID, props: [
                "alignment": "leading", "spacing": .double(defaultSpacing),
            ], children: nodes)
        }
        if tagged {
            row.modifiers.append(rowTag(forEach.tag(element).hash))
        }
        return row
    }
    var props = props
    props["revision"] = .int(graph.currentRevision)
    return RenderNode(type, id: id, props: props, count: count)
}

/// The `tag` modifier of a row a list's selection can name.
func rowTag(_ hash: Int) -> ModifierNode {
    ModifierNode("tag", ["value": .int(hash)])
}

/// Adds `tag` modifiers to the nodes `tags` names, in `node`'s subtree.
func tagRows(_ node: inout RenderNode, _ tags: ItemTags) {
    if let tag = tags.tags[node.id] {
        node.modifiers.append(rowTag(tag.hash))
    }
    for index in node.children.indices {
        tagRows(&node.children[index], tags)
    }
}

/// A list's selection: the `selection` prop and the `change` handler, and,
/// in a split view's column, picking moves the collapsed view on and going
/// back clears it.
func select<Value: Hashable>(
    _ selection: Binding<Value?>,
    list id: RenderNode.ID,
    props: inout [String: PropValue],
    context: RenderContext,
    find: @escaping (Int) -> Value?
) {
    if let value = selection.wrappedValue {
        props["selection"] = .int(value.hashValue)
    }
    let column = context.column
    column?.lists.append { selection.wrappedValue = nil }
    context.graph.on(id, .change) { payload in
        guard let hash = payload?.int else {
            selection.wrappedValue = nil
            return
        }
        guard let value = find(hash) else { return }
        selection.wrappedValue = value
        column?.picked()
    }
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

// MARK: - Selection

/// A list whose rows the user can pick, one at a time.
///
/// Each row it can name has a `tag` modifier with the hash of its value:
/// the element's `id`, or its `tag(_:)` in a list of views. The `List`
/// node's `selection` is the picked row's, absent for none; the host sends
/// `change` with the row the user picks, or with no value for none.
extension List {

    public init<SelectionValue: Hashable>(selection: Binding<SelectionValue?>, @ViewBuilder content: () -> Content) {
        let content = content()
        self.storage = .lazy { context in
            let id = context.graph.nextNodeID()
            let tags = ItemTags()
            var rowContext = context
            rowContext.items = tags
            var rows = rowContext.children(content)
            for index in rows.indices {
                tagRows(&rows[index], tags)
            }
            var props: [String: PropValue] = [:]
            select(selection, list: id, props: &props, context: context) { hash in
                for record in tags.tags.values where record.hash == hash {
                    if let value = record.value(as: SelectionValue.self) {
                        return value
                    }
                }
                return nil
            }
            return RenderNode("List", id: id, props: props, children: rows)
        }
    }

    public init<Data: RandomAccessCollection, Row: View>(
        _ data: Data,
        selection: Binding<Data.Element.ID?>,
        @ViewBuilder rowContent: @escaping (Data.Element) -> Row
    ) where Content == ForEach<Data, Row>, Data.Element: Identifiable {
        self.init(ForEach(data, content: rowContent), selection: selection)
    }

    public init<Data: RandomAccessCollection, ID: Hashable, Row: View>(
        _ data: Data,
        id: @escaping (Data.Element) -> ID,
        selection: Binding<ID?>,
        @ViewBuilder rowContent: @escaping (Data.Element) -> Row
    ) where Content == ForEach<Data, Row> {
        self.init(ForEach(data, id: id, content: rowContent), selection: selection)
    }

    init<Data: RandomAccessCollection, Row: View, SelectionValue: Hashable>(
        _ forEach: ForEach<Data, Row>,
        selection: Binding<SelectionValue?>
    ) where Content == ForEach<Data, Row> {
        self.storage = .lazy { context in
            var list = lazyNode("List", forEach, context: context, tagged: true)
            select(selection, list: list.id, props: &list.props, context: context) { hash in
                for element in forEach.data {
                    let record = forEach.tag(element)
                    if record.hash == hash, let value = record.value(as: SelectionValue.self) {
                        return value
                    }
                }
                return nil
            }
            return list
        }
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

// MARK: - Swipe actions

/// The edge of a row that swipe actions come from.
public enum HorizontalEdge: String, Sendable {
    case leading, trailing
}

/// A list row with swipe actions.
///
/// A `SwipeActions` node's first child is the row, and the rest are its
/// actions: `Button` nodes, which report `tap`. `edge` is `leading` or
/// `trailing`, and `allowsFullSwipe` whether a full swipe runs the first
/// action. A row with actions on both edges is two nested nodes.
public struct _SwipeActionsView<Row: View, Actions: View>: View {

    let row: Row

    let edge: HorizontalEdge

    let allowsFullSwipe: Bool

    let actions: Actions

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let graph = context.graph
        var rowNodes: [RenderNode] = []
        row._render(into: &rowNodes, context: context)
        let id = graph.nextNodeID()
        var children = [singleNode(rowNodes, id: ViewGraph.mix(id, 1))]
        var actionContext = context
        actionContext.items = nil
        graph.scoped { actions._render(into: &children, context: actionContext) }
        nodes.append(RenderNode("SwipeActions", id: id, props: [
            "edge": .string(edge.rawValue),
            "allowsFullSwipe": .bool(allowsFullSwipe),
        ], children: children))
    }
}

extension View {

    /// Buttons revealed by swiping this list row from `edge`.
    public func swipeActions<Actions: View>(
        edge: HorizontalEdge = .trailing,
        allowsFullSwipe: Bool = true,
        @ViewBuilder content: () -> Actions
    ) -> _SwipeActionsView<Self, Actions> {
        _SwipeActionsView(row: self, edge: edge, allowsFullSwipe: allowsFullSwipe, actions: content())
    }
}
