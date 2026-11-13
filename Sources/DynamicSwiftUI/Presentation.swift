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
