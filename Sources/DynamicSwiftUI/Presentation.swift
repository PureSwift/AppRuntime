import DynamicUI

/// `nodes` as one node: the node itself, or a stack of them.
func singleNode(_ nodes: [RenderNode], id: RenderNode.ID) -> RenderNode {
    if nodes.count == 1 {
        return nodes[0]
    }
    return RenderNode("VStack", id: id, props: [
        "alignment": "center", "spacing": .double(defaultSpacing),
    ], children: nodes)
}

// MARK: - Sheets

/// A view that presents a sheet over itself.
///
/// A `Sheet` node's first child is the view it's attached to. While the
/// sheet is presented, `isPresented` is true and the second child is the
/// sheet's content. When the user dismisses the sheet, the host sends
/// `change` with `false`. `style` is `sheet` or `fullScreenCover`.
///
/// The content renders in a scope of its own, keyed by the item it shows,
/// so a sheet for a new item starts with fresh state. `onDismiss` runs when
/// the content goes away, however it was dismissed.
public struct _SheetView<Anchor: View, Content: View>: View {

    let anchor: Anchor

    let style: String

    /// The identity of what's presented, or `nil`.
    let presented: () -> UInt64?

    let dismiss: () -> Void

    let onDismiss: (() -> Void)?

    let content: () -> Content

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let graph = context.graph
        var anchorNodes: [RenderNode] = []
        anchor._render(into: &anchorNodes, context: context)
        let id = graph.nextNodeID()
        let identity = presented()

        // Always one scope, so the views after this keep their identity.
        var children = [singleNode(anchorNodes, id: ViewGraph.mix(id, 1))]
        graph.scoped(identity: identity ?? 0) {
            guard identity != nil else { return }
            var contentContext = context
            contentContext.navigation = nil
            contentContext.items = nil
            contentContext.column = nil
            contentContext.values.dismiss = DismissAction(dismiss)
            contentContext.values.isPresented = true
            contentContext.sheet = id
            var contentNodes: [RenderNode] = []
            content()._render(into: &contentNodes, context: contentContext)
            let root = singleNode(contentNodes, id: ViewGraph.mix(id, 2 &+ (identity ?? 0)))
            if let onDismiss {
                graph.register(ViewGraph.Appearance(node: root.id, onAppear: nil, onDisappear: onDismiss))
            }
            children.append(root)
        }

        let dismiss = self.dismiss
        graph.on(id, .change) { payload in
            if payload?.bool == false { dismiss() }
        }
        nodes.append(RenderNode("Sheet", id: id, props: [
            "isPresented": .bool(identity != nil),
            "style": .string(style),
        ], children: children))
    }
}

extension View {

    /// Presents `content` in a sheet while `isPresented` is true.
    public func sheet<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> _SheetView<Self, Content> {
        _SheetView(anchor: self, style: "sheet", presented: { isPresented.wrappedValue ? 1 : nil },
                   dismiss: { isPresented.wrappedValue = false }, onDismiss: onDismiss, content: content)
    }

    /// Presents a sheet for `item` while it isn't `nil`. A different item
    /// is a new sheet.
    public func sheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> _SheetView<Self, OptionalView<Content>> {
        _SheetView(
            anchor: self,
            style: "sheet",
            presented: { item.wrappedValue.map { UInt64(bitPattern: Int64($0.id.hashValue)) } },
            dismiss: { item.wrappedValue = nil },
            onDismiss: onDismiss,
            content: { OptionalView(content: item.wrappedValue.map(content)) }
        )
    }

    /// Presents `content` over the whole screen while `isPresented` is
    /// true. Hosts without full-screen covers show a sheet.
    public func fullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> _SheetView<Self, Content> {
        _SheetView(anchor: self, style: "fullScreenCover", presented: { isPresented.wrappedValue ? 1 : nil },
                   dismiss: { isPresented.wrappedValue = false }, onDismiss: onDismiss, content: content)
    }
}

// MARK: - Alerts

/// A view that presents an alert over itself.
///
/// An `Alert` node has the alert's `title` and, if it has one, `message`;
/// its first child is the view it's attached to. While the alert is
/// presented, `isPresented` is true and the other children are its actions:
/// `Button` nodes, which report `tap` as usual. Without actions, the host
/// shows an OK button. When the alert goes away, after an action or
/// otherwise, the host sends `change` with `false`.
public struct _AlertView<Anchor: View, Actions: View, Message: View>: View {

    let anchor: Anchor

    let title: String

    let isPresented: Binding<Bool>

    let actions: Actions

    let message: Message?

    /// `nil` for an alert; for a confirmation dialog, `dialog`.
    var style: String? = nil

    var titleVisibility: Visibility = .automatic

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let graph = context.graph
        var anchorNodes: [RenderNode] = []
        anchor._render(into: &anchorNodes, context: context)
        let id = graph.nextNodeID()
        let presented = isPresented.wrappedValue

        // Always one scope, so the views after this keep their identity.
        var children = [singleNode(anchorNodes, id: ViewGraph.mix(id, 1))]
        var messageNodes: [RenderNode] = []
        graph.scoped {
            guard presented else { return }
            var actionContext = context
            actionContext.items = nil
            actions._render(into: &children, context: actionContext)
            message?._render(into: &messageNodes, context: actionContext)
        }

        let isPresented = self.isPresented
        graph.on(id, .change) { payload in
            if payload?.bool == false { isPresented.wrappedValue = false }
        }
        var props: [String: PropValue] = ["title": .string(title), "isPresented": .bool(presented)]
        if let style {
            props["style"] = .string(style)
            props["titleVisibility"] = .string(titleVisibility.rawValue)
        }
        if let text = itemProps(messageNodes)["title"] {
            props["message"] = text
        }
        nodes.append(RenderNode("Alert", id: id, props: props, children: children))
    }
}

extension View {

    /// Presents an alert while `isPresented` is true, with the buttons in
    /// `actions`.
    public func alert<Actions: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: () -> Actions
    ) -> _AlertView<Self, Actions, EmptyView> {
        _AlertView(anchor: self, title: title, isPresented: isPresented, actions: actions(), message: nil)
    }

    /// Presents an alert with a message: a `Text`.
    public func alert<Actions: View, Message: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder message: () -> Message
    ) -> _AlertView<Self, Actions, Message> {
        _AlertView(anchor: self, title: title, isPresented: isPresented, actions: actions(), message: message())
    }
}

// MARK: - Confirmation dialogs

/// Whether something is shown. `automatic` leaves it to the host.
public enum Visibility: String, Sendable {
    case automatic, visible, hidden
}

extension View {

    /// Presents a confirmation dialog, an action sheet on iOS, while
    /// `isPresented` is true: an `Alert` node with `style` `dialog` and a
    /// `titleVisibility`. A host without dialogs shows an alert.
    public func confirmationDialog<Actions: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: () -> Actions
    ) -> _AlertView<Self, Actions, EmptyView> {
        _AlertView(anchor: self, title: title, isPresented: isPresented, actions: actions(), message: nil,
                   style: "dialog", titleVisibility: titleVisibility)
    }

    /// Presents a confirmation dialog with a message.
    public func confirmationDialog<Actions: View, Message: View>(
        _ title: String,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder message: () -> Message
    ) -> _AlertView<Self, Actions, Message> {
        _AlertView(anchor: self, title: title, isPresented: isPresented, actions: actions(), message: message(),
                   style: "dialog", titleVisibility: titleVisibility)
    }
}

// MARK: - Context menus

/// A view with a context menu, shown on a long press or a secondary click.
///
/// A `ContextMenu` node's first child is the view, and the rest are the
/// menu's items: buttons, dividers, sections and menus, which report their
/// own events.
public struct _ContextMenuView<Content: View, Items: View>: View {

    let content: Content

    let items: Items

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let graph = context.graph
        var contentNodes: [RenderNode] = []
        content._render(into: &contentNodes, context: context)
        let id = graph.nextNodeID()
        var children = [singleNode(contentNodes, id: ViewGraph.mix(id, 1))]
        var itemContext = context
        itemContext.items = nil
        graph.scoped { items._render(into: &children, context: itemContext) }
        nodes.append(RenderNode("ContextMenu", id: id, children: children))
    }
}

extension View {

    /// Items shown in a menu when this view is long-pressed.
    public func contextMenu<Items: View>(@ViewBuilder menuItems: () -> Items) -> _ContextMenuView<Self, Items> {
        _ContextMenuView(content: self, items: menuItems())
    }
}

// MARK: - Sheet detents

/// A height a sheet can rest at: SwiftUI's `PresentationDetent`.
public struct PresentationDetent: Equatable, Hashable, Sendable {

    /// `medium`, `large`, `fraction` or `height`.
    let kind: String

    /// The fraction, or the points.
    let value: Double

    /// About half the screen.
    public static let medium = PresentationDetent(kind: "medium", value: 0.5)

    /// The full height a sheet takes.
    public static let large = PresentationDetent(kind: "large", value: 1)

    /// A fraction of the screen's height.
    public static func fraction(_ fraction: Double) -> PresentationDetent {
        PresentationDetent(kind: "fraction", value: fraction)
    }

    /// A height in points.
    public static func height(_ height: Double) -> PresentationDetent {
        PresentationDetent(kind: "height", value: height)
    }

    /// As the IR has it: `medium` or `large`, or `[fraction, 0.3]` and
    /// `[height, 200]`. Embedded Swift can't write a `Double` as text.
    var propValue: PropValue {
        kind == "medium" || kind == "large" ? .string(kind) : .array([.string(kind), .double(value)])
    }

    /// Against the screen's height, about 800 points, for ordering a set.
    var rank: Double {
        kind == "height" ? value / 800 : value
    }
}

/// A sheet's content with its detents: a `presentationDetents` modifier on
/// its root, and the user's choice reported to the `Sheet` node.
public struct _DetentsView<Content: View>: View {

    let content: Content

    let detents: [PresentationDetent]

    let selection: Binding<PresentationDetent>?

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        var produced: [RenderNode] = []
        content._render(into: &produced, context: context)
        var args: [String: PropValue] = ["detents": .array(detents.map { $0.propValue })]
        if let selection, let index = detents.firstIndex(of: selection.wrappedValue) {
            args["selection"] = .int(index)
        }
        for index in produced.indices {
            produced[index].modifiers.append(ModifierNode("presentationDetents", args))
        }
        nodes.append(contentsOf: produced)
        guard let sheet = context.sheet, let selection else { return }
        let detents = self.detents
        context.graph.on(sheet, .detent) { payload in
            guard let index = payload?.int, index >= 0, index < detents.count else { return }
            if selection.wrappedValue != detents[index] {
                selection.wrappedValue = detents[index]
            }
        }
    }
}

extension View {

    /// The heights the sheet this view is the content of can rest at, the
    /// first to start. Where the host has none, the sheet is its
    /// platform's size.
    public func presentationDetents(_ detents: Set<PresentationDetent>) -> _DetentsView<Self> {
        // A set has no order: from smallest to largest, as SwiftUI shows
        // them.
        _DetentsView(content: self, detents: Self.ordered(detents), selection: nil)
    }

    /// The same, with the one it's at: set it to move the sheet, and it
    /// follows the user's drag.
    public func presentationDetents(_ detents: Set<PresentationDetent>, selection: Binding<PresentationDetent>) -> _DetentsView<Self> {
        _DetentsView(content: self, detents: Self.ordered(detents), selection: selection)
    }

    /// An array keeps its order: the first is where the sheet starts.
    public func presentationDetents(_ detents: [PresentationDetent], selection: Binding<PresentationDetent>? = nil) -> _DetentsView<Self> {
        _DetentsView(content: self, detents: detents, selection: selection)
    }

    /// Whether the sheet shows the bar it's dragged by.
    public func presentationDragIndicator(_ visibility: Visibility) -> _ModifierView<Self> {
        modified("presentationDragIndicator", ["visibility": .string(visibility.rawValue)])
    }

    /// True: the user can't swipe the sheet away; the app closes it.
    public func interactiveDismissDisabled(_ isDisabled: Bool = true) -> _ModifierView<Self> {
        modified("interactiveDismissDisabled", ["value": .bool(isDisabled)])
    }

    static func ordered(_ detents: Set<PresentationDetent>) -> [PresentationDetent] {
        detents.sorted { $0.rank < $1.rank || ($0.rank == $1.rank && $0.kind < $1.kind) }
    }
}
