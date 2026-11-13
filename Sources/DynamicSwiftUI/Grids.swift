import DynamicUI

/// A column of a `LazyVGrid` or a row of a `LazyHGrid`.
///
/// In the IR, an array: `[size, a, b, spacing, horizontal, vertical]`, where
/// `size` is `fixed` (`a` is the size, and `b` too), `flexible` or
/// `adaptive` (`a` and `b` are the minimum and maximum), and the last two
/// are the item's alignment. Spacing and alignment are always present: 8
/// and center unless set.
public struct GridItem: Equatable, Sendable {

    public enum Size: Equatable, Sendable {
        /// One item, `size` long.
        case fixed(CGFloat)
        /// One item, as long as the space allows within the bounds.
        case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity)
        /// As many items as fit, each within the bounds.
        case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity)
    }

    public var size: Size

    public var spacing: CGFloat?

    public var alignment: Alignment?

    public init(_ size: Size = .flexible(), spacing: CGFloat? = nil, alignment: Alignment? = nil) {
        self.size = size
        self.spacing = spacing
        self.alignment = alignment
    }

    var propValue: PropValue {
        let size: [PropValue]
        switch self.size {
        case .fixed(let length):
            size = ["fixed", .double(length), .double(length)]
        case .flexible(let minimum, let maximum):
            size = ["flexible", .double(minimum), .double(maximum)]
        case .adaptive(let minimum, let maximum):
            size = ["adaptive", .double(minimum), .double(maximum)]
        }
        let alignment = self.alignment ?? .center
        return .array(size + [
            .double(spacing ?? defaultSpacing),
            .string(alignment.horizontal.rawValue),
            .string(alignment.vertical.rawValue),
        ])
    }
}

/// A grid that grows vertically, with the given columns. Lazy when its
/// content is a `ForEach`: the host asks only for the items it shows.
public struct LazyVGrid<Content: View>: View {

    let make: (RenderContext) -> RenderNode

    /// Renders everything; content that's a `ForEach` takes the lazy initializer.
    @_disfavoredOverload
    public init(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        let content = content()
        let props = gridProps("columns", columns, alignment.rawValue, spacing)
        self.make = { context in
            RenderNode("LazyVGrid", id: context.graph.nextNodeID(), props: props, children: context.children(content))
        }
    }

    public init<Data: RandomAccessCollection, Item: View>(
        columns: [GridItem],
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> ForEach<Data, Item>
    ) where Content == ForEach<Data, Item> {
        let forEach = content()
        let props = gridProps("columns", columns, alignment.rawValue, spacing)
        self.make = { context in lazyNode("LazyVGrid", props: props, forEach, context: context) }
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        nodes.append(make(context))
    }
}

/// A grid that grows horizontally, with the given rows.
public struct LazyHGrid<Content: View>: View {

    let make: (RenderContext) -> RenderNode

    /// Renders everything; content that's a `ForEach` takes the lazy initializer.
    @_disfavoredOverload
    public init(rows: [GridItem], alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        let content = content()
        let props = gridProps("rows", rows, alignment.rawValue, spacing)
        self.make = { context in
            RenderNode("LazyHGrid", id: context.graph.nextNodeID(), props: props, children: context.children(content))
        }
    }

    public init<Data: RandomAccessCollection, Item: View>(
        rows: [GridItem],
        alignment: VerticalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> ForEach<Data, Item>
    ) where Content == ForEach<Data, Item> {
        let forEach = content()
        let props = gridProps("rows", rows, alignment.rawValue, spacing)
        self.make = { context in lazyNode("LazyHGrid", props: props, forEach, context: context) }
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        nodes.append(make(context))
    }
}

/// A grid's props: its columns or rows, alignment and spacing.
func gridProps(_ key: String, _ items: [GridItem], _ alignment: String, _ spacing: CGFloat?) -> [String: PropValue] {
    [
        key: .array(items.map { $0.propValue }),
        "alignment": .string(alignment),
        "spacing": .double(spacing ?? defaultSpacing),
    ]
}

// MARK: - Grid

/// A two-dimensional layout: `GridRow`s, whose views are its cells,
/// aligned in columns. A view in the grid outside a `GridRow` spans every
/// column.
///
/// A `Grid` node has `alignment` (`horizontal`, `vertical`),
/// `horizontalSpacing` and `verticalSpacing`, and its rows as children:
/// `GridRow` nodes, with the cells as children, or other nodes, which span
/// the grid.
public struct Grid<Content: View>: View {

    let alignment: Alignment

    let horizontalSpacing: CGFloat?

    let verticalSpacing: CGFloat?

    let content: Content

    public init(alignment: Alignment = .center, horizontalSpacing: CGFloat? = nil, verticalSpacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.content = content()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        var props = alignment.props
        props["horizontalSpacing"] = .double(horizontalSpacing ?? defaultSpacing)
        props["verticalSpacing"] = .double(verticalSpacing ?? defaultSpacing)
        nodes.append(RenderNode("Grid", id: context.graph.nextNodeID(), props: props, children: context.children(content)))
    }
}

/// A row of a `Grid`: its views are cells, one per column.
public struct GridRow<Content: View>: View {

    let alignment: VerticalAlignment?

    let content: Content

    public init(alignment: VerticalAlignment? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.content = content()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        var props: [String: PropValue] = [:]
        if let alignment {
            props["alignment"] = .string(alignment.rawValue)
        }
        nodes.append(RenderNode("GridRow", id: context.graph.nextNodeID(), props: props, children: context.children(content)))
    }
}
