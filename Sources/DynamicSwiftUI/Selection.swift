import DynamicUI

// MARK: - Tags

/// A tag value, boxed so a picker can read it back as its selection type.
final class TagBox<Value> {

    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// A tag: its value and the type it was made with, since Embedded Swift
/// can't cast. A picker only matches tags of its selection type.
struct TagRecord {

    let type: ObjectIdentifier

    let box: AnyObject

    init<Value: Hashable>(_ value: Value) {
        self.type = ObjectIdentifier(TagBox<Value>.self)
        self.box = TagBox(value)
    }

    /// The value, if it has type `Value`.
    func value<Value: Hashable>(as _: Value.Type) -> Value? {
        guard type == ObjectIdentifier(TagBox<Value>.self) else { return nil }
        return unsafeDowncast(box, to: TagBox<Value>.self).value
    }
}

/// What the options of a picker or the tabs of a tab view say about
/// themselves, by the node ID of each option: `tag(_:)`, a `ForEach`'s
/// implicit tags, and `tabItem(_:)`.
final class ItemTags {

    var tags: [RenderNode.ID: TagRecord] = [:]

    var tabItems: [RenderNode.ID: [String: PropValue]] = [:]

    /// Tags `nodes` with `tag` unless they already have one, so an explicit
    /// `tag(_:)` wins over a `ForEach`'s implicit tag.
    func tag(_ nodes: ArraySlice<RenderNode>, _ tag: TagRecord, replacing: Bool) {
        for node in nodes where replacing || tags[node.id] == nil {
            tags[node.id] = tag
        }
    }

    /// The index of the first of `options` tagged `selection`.
    func index<Value: Hashable>(of selection: Value, in options: [RenderNode]) -> Int? {
        options.firstIndex { tags[$0.id]?.value(as: Value.self) == selection }
    }

    /// The tag of `options[index]`, if it has type `Value`.
    func value<Value: Hashable>(at index: Int, in options: [RenderNode], as type: Value.Type) -> Value? {
        guard options.indices.contains(index) else { return nil }
        return tags[options[index].id]?.value(as: type)
    }
}

public struct _TagView<Content: View, Value: Hashable>: View {

    let content: Content

    let tag: Value

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let start = nodes.count
        content._render(into: &nodes, context: context)
        context.items?.tag(nodes[start...], TagRecord(tag), replacing: true)
    }
}

extension View {

    /// The value a `Picker` sets its selection to when this option is
    /// chosen, or the `TabView` selection that shows this tab. Its type
    /// must be the selection's type.
    public func tag<Value: Hashable>(_ tag: Value) -> _TagView<Self, Value> {
        _TagView(content: self, tag: tag)
    }
}

/// The title and image of a view's nodes, for a picker's label or a tab
/// item: a `Label`'s title and system image, or the first text and image.
func itemProps(_ nodes: [RenderNode]) -> [String: PropValue] {
    var props: [String: PropValue] = [:]
    func visit(_ node: RenderNode) {
        switch node.type {
        case "Label":
            if props["title"] == nil { props["title"] = node.props["title"] }
            if props["systemImage"] == nil { props["systemImage"] = node.props["systemImage"] }
        case "Text":
            if props["title"] == nil { props["title"] = node.props["text"] }
        case "Image":
            if props["systemImage"] == nil { props["systemImage"] = node.props["systemName"] }
        default:
            break
        }
        node.children.forEach(visit)
    }
    nodes.forEach(visit)
    return props
}

// MARK: - Picker

/// Chooses one of its options: each view its content produces, with the
/// value from `tag(_:)` (or a `ForEach`'s element ID).
///
/// A `Picker` node's children are its options, and `selection` is the index
/// of the selected one, absent when no option has the selection's tag. The
/// host sends `change` with the chosen option's index.
public struct Picker<Label: View, SelectionValue: Hashable, Content: View>: View {

    let selection: Binding<SelectionValue>

    let label: Label

    let content: Content

    public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.selection = selection
        self.content = content()
        self.label = label()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let graph = context.graph
        let id = graph.nextNodeID()
        let tags = ItemTags()
        var optionContext = context
        optionContext.items = tags
        let options = optionContext.children(content)
        let selection = self.selection

        var labelContext = context
        labelContext.items = nil
        var props: [String: PropValue] = [:]
        if let title = itemProps(labelContext.children(label))["title"] {
            props["title"] = title
        }
        if let index = tags.index(of: selection.wrappedValue, in: options) {
            props["selection"] = .int(index)
        }
        if let style = context.pickerStyle {
            props["style"] = .string(style)
        }
        graph.on(id, .change) { payload in
            if let index = payload?.int, let value = tags.value(at: index, in: options, as: SelectionValue.self) {
                selection.wrappedValue = value
            }
        }
        nodes.append(RenderNode("Picker", id: id, props: props, children: options))
    }
}

extension Picker where Label == Text {

    public init(_ title: String, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { Text(title) }
    }
}

/// How a picker shows its options. Hosts pick their platform's default for
/// `automatic`, and for a style they don't have.
public protocol PickerStyle {
    var _name: String { get }
}

public struct DefaultPickerStyle: PickerStyle {
    public init() { }
    public var _name: String { "automatic" }
}

public struct MenuPickerStyle: PickerStyle {
    public init() { }
    public var _name: String { "menu" }
}

public struct SegmentedPickerStyle: PickerStyle {
    public init() { }
    public var _name: String { "segmented" }
}

public struct InlinePickerStyle: PickerStyle {
    public init() { }
    public var _name: String { "inline" }
}

/// A spinning wheel, on iOS.
public struct WheelPickerStyle: PickerStyle {
    public init() { }
    public var _name: String { "wheel" }
}

extension PickerStyle where Self == DefaultPickerStyle {
    public static var automatic: DefaultPickerStyle { DefaultPickerStyle() }
}

extension PickerStyle where Self == MenuPickerStyle {
    public static var menu: MenuPickerStyle { MenuPickerStyle() }
}

extension PickerStyle where Self == SegmentedPickerStyle {
    public static var segmented: SegmentedPickerStyle { SegmentedPickerStyle() }
}

extension PickerStyle where Self == InlinePickerStyle {
    public static var inline: InlinePickerStyle { InlinePickerStyle() }
}

extension PickerStyle where Self == WheelPickerStyle {
    public static var wheel: WheelPickerStyle { WheelPickerStyle() }
}

extension View {

    /// The style of the pickers in this view.
    public func pickerStyle<Style: PickerStyle>(_ style: Style) -> _EnvironmentView<Self> {
        let name = style._name
        return _EnvironmentView(content: self) { $0.pickerStyle = name == "automatic" ? nil : name }
    }
}

// MARK: - TabView

/// Tabs: each view its content produces is a tab, titled by its
/// `tabItem(_:)`.
///
/// A `TabView` node's children are `Tab` nodes, one per tab, each with the
/// tab item's `title` and `systemImage` and the tab's content as its only
/// child. `selection` is the shown tab's index. The host sends `change`
/// with the index of the tab the user picks.
///
/// Without a selection binding, the tab view keeps the shown tab itself.
/// With one, tabs are matched by `tag(_:)`, like a picker's options.
public struct TabView<SelectionValue: Hashable, Content: View>: View {

    let selection: Binding<SelectionValue>?

    let content: Content

    public init(selection: Binding<SelectionValue>?, @ViewBuilder content: () -> Content) {
        self.selection = selection
        self.content = content()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let graph = context.graph
        let id = graph.nextNodeID()
        let shown = graph.stateBox { 0 }
        let tags = ItemTags()
        var tabContext = context
        tabContext.items = tags
        let pages = tabContext.children(content)

        let index: Int?
        if let selection {
            index = tags.index(of: selection.wrappedValue, in: pages)
        } else {
            index = pages.isEmpty ? nil : Swift.min(Swift.max(0, shown.value), pages.count - 1)
        }
        let selection = self.selection
        graph.on(id, .change) { payload in
            guard let new = payload?.int, pages.indices.contains(new) else { return }
            if let selection {
                if let value = tags.value(at: new, in: pages, as: SelectionValue.self) {
                    selection.wrappedValue = value
                }
            } else {
                shown.value = new
            }
        }

        let tabs = pages.map { page in
            RenderNode("Tab", id: ViewGraph.mix(page.id ^ 0x5441_4200_0000_0000, 0),
                       props: tags.tabItems[page.id] ?? [:], children: [page])
        }
        var props: [String: PropValue] = [:]
        if let index {
            props["selection"] = .int(index)
        }
        nodes.append(RenderNode("TabView", id: id, props: props, children: tabs))
    }
}

extension TabView where SelectionValue == Int {

    public init(@ViewBuilder content: () -> Content) {
        self.selection = nil
        self.content = content()
    }
}

public struct _TabItemView<Content: View, Item: View>: View {

    let content: Content

    let item: Item

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let start = nodes.count
        content._render(into: &nodes, context: context)
        var itemContext = context
        itemContext.items = nil
        let props = itemProps(itemContext.children(item))
        for node in nodes[start...] {
            context.items?.tabItems[node.id] = props
        }
    }
}

extension View {

    /// The title and image of this view's tab in a `TabView`: a `Label`, or
    /// a `Text` and an `Image`.
    public func tabItem<Item: View>(@ViewBuilder _ label: () -> Item) -> _TabItemView<Self, Item> {
        _TabItemView(content: self, item: label())
    }
}
