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
            levels.append(RenderNode("NavLevel", id: ViewGraph.mix(id, UInt64(depth)), props: props, children: content))
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
