import DynamicUI

// MARK: - Visibility, columns and styles

/// Which of a split view's columns show, side by side.
public struct NavigationSplitViewVisibility: Equatable, Sendable {

    let name: String

    /// The host's choice for the width.
    public static let automatic = NavigationSplitViewVisibility(name: "automatic")
    /// Every column.
    public static let all = NavigationSplitViewVisibility(name: "all")
    /// The content and the detail: the sidebar of three is hidden.
    public static let doubleColumn = NavigationSplitViewVisibility(name: "doubleColumn")
    /// The detail alone.
    public static let detailOnly = NavigationSplitViewVisibility(name: "detailOnly")

    init(name: String) {
        self.name = name
    }

    init?(_ name: String) {
        guard ["automatic", "all", "doubleColumn", "detailOnly"].contains(name) else { return nil }
        self.name = name
    }
}

/// One of a split view's columns.
public struct NavigationSplitViewColumn: Equatable, Sendable {

    let name: String

    public static let sidebar = NavigationSplitViewColumn(name: "sidebar")
    /// The middle column of three.
    public static let content = NavigationSplitViewColumn(name: "content")
    public static let detail = NavigationSplitViewColumn(name: "detail")
}

/// How a split view shares its width. Hosts pick their platform's way for
/// `automatic`.
public protocol NavigationSplitViewStyle {
    var _name: String { get }
}

public struct AutomaticNavigationSplitViewStyle: NavigationSplitViewStyle {
    public init() { }
    public var _name: String { "automatic" }
}

/// Narrows the detail so the sidebar fits beside it.
public struct BalancedNavigationSplitViewStyle: NavigationSplitViewStyle {
    public init() { }
    public var _name: String { "balanced" }
}

/// Keeps the detail's width, and lays the sidebar over it.
public struct ProminentDetailNavigationSplitViewStyle: NavigationSplitViewStyle {
    public init() { }
    public var _name: String { "prominentDetail" }
}

extension NavigationSplitViewStyle where Self == AutomaticNavigationSplitViewStyle {
    public static var automatic: AutomaticNavigationSplitViewStyle { AutomaticNavigationSplitViewStyle() }
}

extension NavigationSplitViewStyle where Self == BalancedNavigationSplitViewStyle {
    public static var balanced: BalancedNavigationSplitViewStyle { BalancedNavigationSplitViewStyle() }
}

extension NavigationSplitViewStyle where Self == ProminentDetailNavigationSplitViewStyle {
    public static var prominentDetail: ProminentDetailNavigationSplitViewStyle { ProminentDetailNavigationSplitViewStyle() }
}

// MARK: - State

/// A column while it renders: its widths, and the lists in it, which tell
/// it when the user picks a row.
final class SplitColumn {

    /// Moves a collapsed split view on to the next column.
    let picked: () -> Void

    /// Clears the selection of each list in the column.
    var lists: [() -> Void] = []

    var minWidth: Double?

    var idealWidth: Double?

    var maxWidth: Double?

    init(picked: @escaping () -> Void) {
        self.picked = picked
    }
}

/// What a split view keeps between updates: the column a collapsed view
/// shows, and the link each column shows the destination of.
final class SplitState {

    let names: [String]

    let compactBox: StateBox<Int>

    var binding: Binding<NavigationSplitViewColumn>?

    /// By column: the link whose destination it shows, in place of its own
    /// content.
    let links: StateBox<[RenderNode.ID?]>

    /// By column, from the latest update: what clears each of its lists'
    /// selection. Closures over bindings, so nothing here holds the state.
    var clears: [[() -> Void]] = []

    init(names: [String], compactBox: StateBox<Int>, links: StateBox<[RenderNode.ID?]>) {
        self.names = names
        self.compactBox = compactBox
        self.links = links
    }

    /// The column a collapsed view shows, sidebar 0.
    var compact: Int {
        get {
            let index: Int
            if let binding {
                index = names.firstIndex(of: binding.wrappedValue.name) ?? (names.count - 1)
            } else {
                index = compactBox.value
            }
            return Swift.min(Swift.max(0, index), names.count - 1)
        }
        set {
            let index = Swift.min(Swift.max(0, newValue), names.count - 1)
            if let binding {
                binding.wrappedValue = NavigationSplitViewColumn(name: names[index])
            } else {
                compactBox.value = index
            }
        }
    }

    /// The user picked a row in `column`.
    func picked(from column: Int) {
        if column + 1 < names.count {
            compact = column + 1
        }
    }

    /// The user followed a link in `column`: its destination shows in the
    /// next one.
    func follow(_ link: RenderNode.ID, from column: Int) {
        guard column + 1 < names.count else { return }
        var links = self.links.value
        for index in links.indices where index > column {
            links[index] = nil
        }
        links[column + 1] = link
        self.links.value = links
        compact = column + 1
    }

    /// The user went back, leaving `left` columns: the one now shown loses
    /// its lists' selection, and the ones after it their links.
    func back(leaving left: Int) {
        let shown = Swift.min(Swift.max(0, left - 1), names.count - 1)
        if links.value.indices.contains(where: { $0 > shown && links.value[$0] != nil }) {
            var links = self.links.value
            for index in links.indices where index > shown {
                links[index] = nil
            }
            self.links.value = links
        }
        if clears.indices.contains(shown) {
            for clear in clears[shown] {
                clear()
            }
        }
        compact = shown
    }
}

// MARK: - NavigationSplitView

/// Two or three columns side by side, which the host shows as a stack at
/// compact width.
///
/// A `NavSplit` node's children are its `NavColumn`s, the sidebar first,
/// each with its `column`, `title` and widths, and its content then its
/// `ToolbarItem`s. `visibility` is which columns show, and `compactColumn`
/// the one a collapsed view shows. The host sends `change` with the
/// visibility the user chose, and `pop` with the number of columns left
/// when the user goes back.
///
/// Picking a row in a column's `List(selection:)`, or following a link in
/// it, shows the next column. A link's destination takes the place of that
/// column's own content. Going back clears the selection of the column it
/// goes back to.
///
/// On a renderer that doesn't report the window's values, and so doesn't
/// draw split views, it's a `NavStack`: the sidebar is
/// its root, and each column up to the compact one a level.
public struct NavigationSplitView<Sidebar: View, Content: View, Detail: View>: View {

    let columnVisibility: Binding<NavigationSplitViewVisibility>?

    let preferredCompactColumn: Binding<NavigationSplitViewColumn>?

    let sidebar: Sidebar

    let content: Content?

    let detail: Detail

    public init(
        columnVisibility: Binding<NavigationSplitViewVisibility>? = nil,
        preferredCompactColumn: Binding<NavigationSplitViewColumn>? = nil,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder content: () -> Content,
        @ViewBuilder detail: () -> Detail
    ) {
        self.columnVisibility = columnVisibility
        self.preferredCompactColumn = preferredCompactColumn
        self.sidebar = sidebar()
        self.content = content()
        self.detail = detail()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let graph = context.graph
        let id = graph.nextNodeID()
        let names = content == nil ? ["sidebar", "detail"] : ["sidebar", "content", "detail"]
        let compactBox = graph.stateBox { 0 }
        let visibilityBox = graph.stateBox { NavigationSplitViewVisibility.automatic }
        let links = graph.stateBox { [RenderNode.ID?](repeating: nil, count: names.count) }
        let destinations = graph.stateBox { NavigationDestinations() }.value
        let state = graph.stateBox { SplitState(names: names, compactBox: compactBox, links: links) }.value
        state.binding = preferredCompactColumn

        let compact = state.compact
        let asStack = !graph.supportsSplitViews
        let collapsed = asStack || context.values.window.horizontalSizeClass == .compact
        // A stack shows the columns up to the compact one; a split view all.
        let shown = asStack ? compact + 1 : names.count

        var columns: [RenderNode] = []
        var titles: [String?] = []
        state.clears = []
        graph.scoped {
            for index in 0..<shown {
                let column = SplitColumn { state.picked(from: index) }
                let level = NavigationLevel(destinations: destinations) { link in
                    state.follow(link, from: index)
                }
                var columnContext = context
                columnContext.navigation = level
                columnContext.column = column
                columnContext.items = nil
                columnContext.splitStyle = nil
                if index > 0 {
                    columnContext.values.dismiss = DismissAction {
                        if collapsed, state.compact >= index {
                            state.back(leaving: index)
                        }
                    }
                }
                var produced: [RenderNode] = []
                graph.scoped(identity: UInt64(index)) {
                    if index > 0, let link = links.value[index], let destination = destinations.table[link] {
                        graph.scoped(identity: link) {
                            destination(&produced, columnContext)
                        }
                    } else {
                        render(column: index, of: names.count, into: &produced, context: columnContext)
                    }
                }
                var props: [String: PropValue] = ["column": .string(names[index])]
                if let title = level.title { props["title"] = .string(title) }
                if let width = column.minWidth { props["minWidth"] = .double(width) }
                if let width = column.idealWidth { props["idealWidth"] = .double(width) }
                if let width = column.maxWidth { props["maxWidth"] = .double(width) }
                state.clears.append(column.lists)
                titles.append(level.title)
                columns.append(RenderNode("NavColumn", id: ViewGraph.mix(id ^ 0x434f_4c00_0000_0000, UInt64(index)),
                                          props: props, children: produced + level.toolbar))
            }
        }

        graph.on(id, .pop) { payload in
            if let left = payload?.int {
                state.back(leaving: left)
            }
        }

        if asStack {
            let levels = columns.enumerated().map { index, column in
                var props: [String: PropValue] = [:]
                if let title = titles[index] { props["title"] = .string(title) }
                return RenderNode("NavLevel", id: ViewGraph.mix(id, UInt64(index)), props: props, children: column.children)
            }
            nodes.append(RenderNode("NavStack", id: id, children: levels))
            return
        }

        let binding = columnVisibility
        graph.on(id, .change) { payload in
            guard let name = payload?.string, let visibility = NavigationSplitViewVisibility(name) else { return }
            if let binding {
                binding.wrappedValue = visibility
            } else {
                visibilityBox.value = visibility
            }
        }
        let visibility = columnVisibility?.wrappedValue ?? visibilityBox.value
        nodes.append(RenderNode("NavSplit", id: id, props: [
            "style": .string(context.splitStyle ?? "automatic"),
            "visibility": .string(visibility.name),
            "compactColumn": .string(names[compact]),
        ], children: columns))
    }

    private func render(column index: Int, of count: Int, into nodes: inout [RenderNode], context: RenderContext) {
        if index == 0 {
            sidebar._render(into: &nodes, context: context)
        } else if index == count - 1 {
            detail._render(into: &nodes, context: context)
        } else {
            content?._render(into: &nodes, context: context)
        }
    }
}

extension NavigationSplitView where Content == EmptyView {

    /// A sidebar and a detail.
    public init(
        columnVisibility: Binding<NavigationSplitViewVisibility>? = nil,
        preferredCompactColumn: Binding<NavigationSplitViewColumn>? = nil,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail
    ) {
        self.columnVisibility = columnVisibility
        self.preferredCompactColumn = preferredCompactColumn
        self.sidebar = sidebar()
        self.content = nil
        self.detail = detail()
    }
}

// MARK: - Modifiers

/// Sets the widths of the split view column a view is in.
public struct _SplitColumnWidthView<Content: View>: View {

    let content: Content

    let min: Double?

    let ideal: Double?

    let max: Double?

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        if let column = context.column {
            column.minWidth = min
            column.idealWidth = ideal
            column.maxWidth = max
        }
        content._render(into: &nodes, context: context)
    }
}

extension View {

    /// The width of the split view column this view is in, in points.
    public func navigationSplitViewColumnWidth(_ width: CGFloat) -> _SplitColumnWidthView<Self> {
        _SplitColumnWidthView(content: self, min: nil, ideal: width, max: nil)
    }

    /// The widths of the split view column this view is in, in points.
    public func navigationSplitViewColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil) -> _SplitColumnWidthView<Self> {
        _SplitColumnWidthView(content: self, min: min, ideal: ideal, max: max)
    }

    /// How the split views in this view share their width.
    public func navigationSplitViewStyle<Style: NavigationSplitViewStyle>(_ style: Style) -> _EnvironmentView<Self> {
        let name = style._name
        return _EnvironmentView(content: self) { $0.splitStyle = name == "automatic" ? nil : name }
    }
}
