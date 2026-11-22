import DynamicUI

extension RenderContext {

    /// A node with the next ID at this position.
    func node(
        _ type: String,
        props: [String: PropValue] = [:],
        children: [RenderNode] = [],
        count: Int? = nil
    ) -> RenderNode {
        RenderNode(type, id: graph.nextNodeID(), props: props, children: children, count: count)
    }

    /// Renders `content` in a child scope, for a container's children.
    func children<Content: View>(_ content: Content) -> [RenderNode] {
        var nodes: [RenderNode] = []
        graph.scoped {
            content._render(into: &nodes, context: self)
        }
        return nodes
    }
}

/// A primitive view that emits one node; `make` gets the node's ID.
protocol PrimitiveView: View where Body == Never {
    func makeNode(_ id: RenderNode.ID, context: RenderContext) -> RenderNode
}

extension PrimitiveView {

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        nodes.append(makeNode(context.graph.nextNodeID(), context: context))
    }
}

// MARK: - Text and images

public struct Text: PrimitiveView {

    let content: String

    public init(_ content: String) {
        self.content = content
    }

    public init(verbatim content: String) {
        self.content = content
    }

    func makeNode(_ id: RenderNode.ID, context: RenderContext) -> RenderNode {
        RenderNode("Text", id: id, props: ["text": .string(content)])
    }
}

public struct Image: PrimitiveView {

    var props: [String: PropValue]

    /// A symbol: SF Symbols on Apple hosts; other hosts map common names.
    public init(systemName: String) {
        self.props = ["systemName": .string(systemName)]
    }

    /// An image from the app's bundle resources.
    public init(_ name: String) {
        self.props = ["name": .string(name)]
    }

    /// Scales to fill its frame instead of keeping its natural size.
    public func resizable() -> Image {
        var image = self
        image.props["resizable"] = .bool(true)
        return image
    }

    func makeNode(_ id: RenderNode.ID, context: RenderContext) -> RenderNode {
        RenderNode("Image", id: id, props: props)
    }
}

public struct Label: PrimitiveView {

    let title: String

    let systemImage: String

    public init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    func makeNode(_ id: RenderNode.ID, context: RenderContext) -> RenderNode {
        RenderNode("Label", id: id, props: ["title": .string(title), "systemImage": .string(systemImage)])
    }
}

/// Takes up the free space along its stack's axis.
public struct Spacer: PrimitiveView {

    let minLength: Double?

    public init(minLength: CGFloat? = nil) {
        self.minLength = minLength
    }

    func makeNode(_ id: RenderNode.ID, context: RenderContext) -> RenderNode {
        RenderNode("Spacer", id: id, props: ["minLength": .double(minLength ?? defaultSpacing)])
    }
}

public struct Divider: PrimitiveView {

    public init() { }

    func makeNode(_ id: RenderNode.ID, context: RenderContext) -> RenderNode {
        RenderNode("Divider", id: id)
    }
}

/// A color is also a view that fills its space.
extension Color: PrimitiveView {

    func makeNode(_ id: RenderNode.ID, context: RenderContext) -> RenderNode {
        RenderNode("Color", id: id, props: ["color": propValue])
    }
}

// MARK: - Stacks

public struct VStack<Content: View>: View {

    let alignment: HorizontalAlignment

    let spacing: Double?

    let content: Content

    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let id = context.graph.nextNodeID()
        nodes.append(RenderNode("VStack", id: id, props: [
            "alignment": .string(alignment.rawValue),
            "spacing": .double(spacing ?? defaultSpacing),
        ], children: context.children(content)))
    }
}

public struct HStack<Content: View>: View {

    let alignment: VerticalAlignment

    let spacing: Double?

    let content: Content

    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let id = context.graph.nextNodeID()
        nodes.append(RenderNode("HStack", id: id, props: [
            "alignment": .string(alignment.rawValue),
            "spacing": .double(spacing ?? defaultSpacing),
        ], children: context.children(content)))
    }
}

/// Children drawn on top of each other, the last frontmost.
public struct ZStack<Content: View>: View {

    let alignment: Alignment

    let content: Content

    public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let id = context.graph.nextNodeID()
        nodes.append(RenderNode("ZStack", id: id, props: alignment.props, children: context.children(content)))
    }
}

public struct ScrollView<Content: View>: View {

    let axes: Axis.Set

    let showsIndicators: Bool

    let content: Content

    public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.showsIndicators = showsIndicators
        self.content = content()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let id = context.graph.nextNodeID()
        let axes: String = self.axes == [.horizontal, .vertical] ? "both" : self.axes.contains(.horizontal) ? "horizontal" : "vertical"
        nodes.append(RenderNode("ScrollView", id: id, props: [
            "axes": .string(axes),
            "showsIndicators": .bool(showsIndicators),
        ], children: context.children(content)))
    }
}

// MARK: - ForEach

/// One view per element of `data`. Each element's state and node IDs follow
/// its identity: the `id` of `Identifiable` data, an `id` closure's value, or
/// the position in a range.
///
/// In a `Picker` or `TabView`, each element's views are tagged with its
/// identity value, unless they have a `tag(_:)` of their own.
public struct ForEach<Data: RandomAccessCollection, Content: View>: View {

    let data: Data

    let content: (Data.Element) -> Content

    let identity: (Data.Element) -> UInt64

    /// The element's implicit tag.
    let tag: (Data.Element) -> TagRecord

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let graph = context.graph
        graph.scoped {
            for element in data {
                let start = nodes.count
                graph.scoped(identity: identity(element)) {
                    content(element)._render(into: &nodes, context: context)
                }
                context.items?.tag(nodes[start...], tag(element), replacing: false)
            }
        }
    }

    /// The element at a position, for lazy containers.
    func element(_ index: Int) -> Data.Element {
        data[data.index(data.startIndex, offsetBy: index)]
    }
}

extension ForEach where Data == Range<Int> {

    public init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> Content) {
        self.data = data
        self.content = content
        self.identity = { UInt64(bitPattern: Int64($0)) }
        self.tag = { TagRecord($0) }
    }
}

extension ForEach where Data.Element: Identifiable {

    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
        self.identity = { UInt64(bitPattern: Int64($0.id.hashValue)) }
        self.tag = { TagRecord($0.id) }
    }
}

extension ForEach {

    /// Identified by a value of each element. Takes a closure where SwiftUI
    /// takes a key path, which Embedded Swift doesn't have.
    public init<ID: Hashable>(_ data: Data, id: @escaping (Data.Element) -> ID, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
        self.identity = { UInt64(bitPattern: Int64(id($0).hashValue)) }
        self.tag = { TagRecord(id($0)) }
    }
}

/// Where a `Surface` draws with OpenGL ES (§8.2): the host puts its GL view
/// here, laid out, layered and clipped like any other view.
///
/// ```swift
/// GLSurface(surface.identifier())
///     .frame(height: 240)
/// ```
///
/// It takes the space offered. Views over it in a `ZStack` get their
/// pointers first; the rest go to the surface's delegate.
public struct GLSurface: PrimitiveView {

    let surface: Int32

    /// - Parameter surface: The surface's `identifier()`.
    public init(_ surface: Int32) {
        self.surface = surface
    }

    func makeNode(_ id: RenderNode.ID, context: RenderContext) -> RenderNode {
        RenderNode("GLSurface", id: id, props: ["surface": .int(Int(surface))])
    }
}

/// A view that is one render node, for a module that adds a node of its
/// own to the vocabulary, as `WebKit`'s `WebView` does. A player that
/// doesn't know the type shows a placeholder (§9.2).
///
/// The node gets its identity from the view's position, like any other, so
/// wrap it in a view of your own rather than building it in a loop.
public struct _RenderNodeView: PrimitiveView {

    let type: String

    let props: [String: PropValue]

    public init(_ type: String, props: [String: PropValue] = [:]) {
        self.type = type
        self.props = props
    }

    func makeNode(_ id: RenderNode.ID, context: RenderContext) -> RenderNode {
        RenderNode(type, id: id, props: props)
    }
}

/// A view that is one render node with children, for a module that adds a
/// container to the vocabulary, as `MapKit`'s `Map` does: its content is
/// rendered as the node's children, and it handles its own events.
///
/// With a selection, the children with a `tag(_:)` get a `tag` modifier,
/// the node a `selection` prop, and a `change` event sets the binding, as
/// `List(selection:)` does.
public struct _RenderContainerView<Content: View, SelectionValue: Hashable>: View {

    let type: String

    let props: [String: PropValue]

    let selection: Binding<SelectionValue?>?

    let events: [RenderEventKind: (PropValue?) -> Void]

    let content: Content

    public init(
        _ type: String,
        props: [String: PropValue] = [:],
        selection: Binding<SelectionValue?>?,
        events: [RenderEventKind: (PropValue?) -> Void] = [:],
        @ViewBuilder content: () -> Content
    ) {
        self.type = type
        self.props = props
        self.selection = selection
        self.events = events
        self.content = content()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let graph = context.graph
        let id = graph.nextNodeID()
        var props = self.props
        var childContext = context
        let tags = ItemTags()
        childContext.items = selection == nil ? nil : tags
        var children = childContext.children(content)
        if let selection {
            for index in children.indices {
                tagRows(&children[index], tags)
            }
            select(selection, list: id, props: &props, context: context, inColumn: false) { hash in
                for record in tags.tags.values where record.hash == hash {
                    if let value = record.value(as: SelectionValue.self) {
                        return value
                    }
                }
                return nil
            }
        }
        for (kind, handler) in events {
            graph.on(id, kind, handler)
        }
        nodes.append(RenderNode(type, id: id, props: props, children: children))
    }
}

extension _RenderContainerView where SelectionValue == Int {

    public init(
        _ type: String,
        props: [String: PropValue] = [:],
        events: [RenderEventKind: (PropValue?) -> Void] = [:],
        @ViewBuilder content: () -> Content
    ) {
        self.init(type, props: props, selection: nil, events: events, content: content)
    }
}

