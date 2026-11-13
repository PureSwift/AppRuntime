import DynamicUI

/// Destinations of the navigation links a stack has seen, by link node ID.
/// Kept across updates, so links in lazy rows (rendered only when the host
/// asks) can still be followed.
final class NavigationDestinations {
    var table: [RenderNode.ID: (inout [RenderNode], RenderContext) -> Void] = [:]
}

/// One level of a navigation stack while it renders: collects its title and
/// the links it shows.
final class NavigationLevel {

    let path: StateBox<[RenderNode.ID]>

    let destinations: NavigationDestinations

    let depth: Int

    var title: String?

    /// `ToolbarItem` nodes from `toolbar(content:)`, after the content.
    var toolbar: [RenderNode] = []

    init(path: StateBox<[RenderNode.ID]>, destinations: NavigationDestinations, depth: Int) {
        self.path = path
        self.destinations = destinations
        self.depth = depth
    }

    /// Shows `link`'s destination on top of this level, replacing deeper ones.
    func push(_ link: RenderNode.ID) {
        path.value = Array(path.value.prefix(depth)) + [link]
    }
}

/// A stack of views the user moves through with links and back navigation.
///
/// The path is a list of link IDs, one per pushed level. Each update renders
/// the root, then the destination of the link pushed from it, and so on, so
/// pushed views stay live. A `NavStack` node's children are its levels
/// (`NavLevel` nodes, with a `title`); the host sends `pop` with the number
/// of levels left when the user goes back.
public struct NavigationStack<Root: View>: View {

    let root: Root

    public init(@ViewBuilder root: () -> Root) {
        self.root = root()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let graph = context.graph
        let id = graph.nextNodeID()
        let path = graph.stateBox { [RenderNode.ID]() }
        let destinations = graph.stateBox { NavigationDestinations() }.value

        var levels: [RenderNode] = []
        var depth = 0
        while true {
            let level = NavigationLevel(path: path, destinations: destinations, depth: depth)
            var levelContext = context
            levelContext.navigation = level
            var content: [RenderNode] = []
            if depth == 0 {
                graph.scoped(identity: 0) {
                    root._render(into: &content, context: levelContext)
                }
            } else {
                let link = path.value[depth - 1]
                guard let destination = destinations.table[link] else { break }
                graph.scoped(identity: link) {
                    destination(&content, levelContext)
                }
            }
            var props: [String: PropValue] = [:]
            if let title = level.title {
                props["title"] = .string(title)
            }
            levels.append(RenderNode("NavLevel", id: ViewGraph.mix(id, UInt64(depth)), props: props, children: content + level.toolbar))
            depth += 1
            guard depth <= path.value.count else { break }
        }

        graph.on(id, .pop) { payload in
            if let left = payload?.int {
                path.value = Array(path.value.prefix(Swift.max(0, left - 1)))
            }
        }
        nodes.append(RenderNode("NavStack", id: id, children: levels))
    }
}

/// Pushes `destination` onto the enclosing `NavigationStack` when tapped.
public struct NavigationLink<Label: View, Destination: View>: View {

    let destination: Destination

    let label: Label

    public init(destination: Destination, @ViewBuilder label: () -> Label) {
        self.destination = destination
        self.label = label()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let graph = context.graph
        let id = graph.nextNodeID()
        if let level = context.navigation {
            let destination = self.destination
            level.destinations.table[id] = { nodes, context in
                destination._render(into: &nodes, context: context)
            }
            graph.on(id, .tap) { _ in level.push(id) }
        }
        nodes.append(RenderNode("NavigationLink", id: id, children: context.children(label)))
    }
}

extension NavigationLink where Label == Text {

    public init(_ title: String, destination: Destination) {
        self.init(destination: destination) { Text(title) }
    }
}

/// Sets the title of the navigation level a view is in.
public struct _NavigationTitleView<Content: View>: View {

    let content: Content

    let title: String

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        context.navigation?.title = title
        content._render(into: &nodes, context: context)
    }
}

extension View {

    public func navigationTitle(_ title: String) -> _NavigationTitleView<Self> {
        _NavigationTitleView(content: self, title: title)
    }
}

// MARK: - Toolbars

/// Where a toolbar item goes. Hosts put an item they have no place for
/// where `automatic` items go.
public struct ToolbarItemPlacement: Equatable, Sendable {

    let name: String

    public static let automatic = ToolbarItemPlacement(name: "automatic")
    /// The most used action: the trailing end of an iOS navigation bar.
    public static let primaryAction = ToolbarItemPlacement(name: "primaryAction")
    /// Dismisses without saving, in a sheet.
    public static let cancellationAction = ToolbarItemPlacement(name: "cancellationAction")
    /// Confirms, in a sheet.
    public static let confirmationAction = ToolbarItemPlacement(name: "confirmationAction")
    /// The leading end of a navigation bar.
    public static let navigation = ToolbarItemPlacement(name: "navigation")
    /// The center of a navigation bar.
    public static let principal = ToolbarItemPlacement(name: "principal")
    /// The bottom toolbar, on iOS.
    public static let bottomBar = ToolbarItemPlacement(name: "bottomBar")
}

/// A toolbar item: its content, at a placement. Also `ToolbarItemGroup`,
/// for several views at one placement.
public struct ToolbarItem<Content: View>: View {

    let placement: ToolbarItemPlacement

    let content: Content

    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {
        self.placement = placement
        self.content = content()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let id = context.graph.nextNodeID()
        nodes.append(RenderNode("ToolbarItem", id: id, props: ["placement": .string(placement.name)],
                                children: context.children(content)))
    }
}

public typealias ToolbarItemGroup = ToolbarItem

/// Adds toolbar items to the navigation level a view is in.
///
/// A `NavLevel` node's `ToolbarItem` children, after its content, are its
/// toolbar: each has a `placement` and its views as children. Views that
/// aren't in a `ToolbarItem` go in an `automatic` one each. Outside a
/// navigation stack, the items aren't shown.
public struct _ToolbarView<Content: View, Items: View>: View {

    let content: Content

    let items: Items

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        content._render(into: &nodes, context: context)
        let graph = context.graph
        var itemContext = context
        itemContext.items = nil
        var produced: [RenderNode] = []
        // Always one scope, so the views after this keep their identity.
        graph.scoped {
            items._render(into: &produced, context: itemContext)
        }
        guard let level = context.navigation else { return }
        for node in produced {
            if node.type == "ToolbarItem" {
                level.toolbar.append(node)
            } else {
                level.toolbar.append(RenderNode("ToolbarItem", id: ViewGraph.mix(node.id ^ 0x544f_4f4c_0000_0000, 0),
                                                props: ["placement": "automatic"], children: [node]))
            }
        }
    }
}

extension View {

    /// Toolbar items for the navigation level this view is in: views, or
    /// `ToolbarItem`s with a placement.
    public func toolbar<Items: View>(@ViewBuilder content: () -> Items) -> _ToolbarView<Self, Items> {
        _ToolbarView(content: self, items: content())
    }
}

// MARK: - Search

/// A view with a search field, which the host puts in the navigation bar of
/// the level it's in.
///
/// A `Searchable` node has the field's `text` and `prompt`, and the view as
/// its only child. The host sends `change` with the text as the user types,
/// and `submit` when they search; `onSubmit(_:)` around the view handles it.
public struct _SearchableView<Content: View>: View {

    let content: Content

    let text: Binding<String>

    let prompt: String?

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let graph = context.graph
        var contentNodes: [RenderNode] = []
        content._render(into: &contentNodes, context: context)
        let id = graph.nextNodeID()
        let text = self.text
        graph.on(id, .change) { payload in
            if let value = payload?.string { text.wrappedValue = value }
        }
        if let onSubmit = context.onSubmit {
            graph.on(id, .submit) { _ in onSubmit() }
        }
        var props: [String: PropValue] = ["text": .string(text.wrappedValue)]
        if let prompt {
            props["prompt"] = .string(prompt)
        }
        nodes.append(RenderNode("Searchable", id: id, props: props, children: [singleNode(contentNodes, id: ViewGraph.mix(id, 1))]))
    }
}

extension View {

    /// Adds a search field for `text`, in the navigation bar.
    public func searchable(text: Binding<String>, prompt: String? = nil) -> _SearchableView<Self> {
        _SearchableView(content: self, text: text, prompt: prompt)
    }
}
