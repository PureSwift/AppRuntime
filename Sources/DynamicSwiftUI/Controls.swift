import DynamicUI

/// Controls carry their current value in props and report changes through
/// `RendererDelegate.event`. The guest's state is the source of truth; a host
/// sets a control from the IR only when the value differs from what it last
/// rendered, so typing or dragging isn't overwritten (§9.5).

/// What a button does, for hosts to style it: `role` in the IR.
public struct ButtonRole: Equatable, Sendable {

    let name: String

    /// Deletes or removes something.
    public static let destructive = ButtonRole(name: "destructive")

    /// Cancels, as in an alert.
    public static let cancel = ButtonRole(name: "cancel")
}

public struct Button<Content: View>: View {

    let action: () -> Void

    let role: ButtonRole?

    let label: Content

    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Content) {
        self.action = action
        self.role = nil
        self.label = label()
    }

    public init(role: ButtonRole?, action: @escaping () -> Void, @ViewBuilder label: () -> Content) {
        self.action = action
        self.role = role
        self.label = label()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let graph = context.graph
        let id = graph.nextNodeID()
        let action = self.action
        graph.on(id, .tap) { _ in action() }
        let props: [String: PropValue] = role.map { ["role": .string($0.name)] } ?? [:]
        nodes.append(RenderNode("Button", id: id, props: props, children: context.children(label)))
    }
}

extension Button where Content == Text {

    public init(_ title: String, action: @escaping () -> Void) {
        self.init(action: action) { Text(title) }
    }

    public init(_ title: String, role: ButtonRole?, action: @escaping () -> Void) {
        self.init(role: role, action: action) { Text(title) }
    }
}

extension Button where Content == Label {

    public init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.init(action: action) { Label(title, systemImage: systemImage) }
    }
}

public struct Toggle<Label: View>: View {

    let isOn: Binding<Bool>

    let label: Label

    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self.isOn = isOn
        self.label = label()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let graph = context.graph
        let id = graph.nextNodeID()
        let isOn = self.isOn
        graph.on(id, .change) { payload in
            if let value = payload?.bool { isOn.wrappedValue = value }
        }
        nodes.append(RenderNode("Toggle", id: id, props: ["isOn": .bool(isOn.wrappedValue)],
                                children: context.children(label)))
    }
}

extension Toggle where Label == Text {

    public init(_ title: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(title) }
    }
}

/// A single-line text field. `secure` hides what's typed (`SecureField`).
public struct TextField: View {

    let placeholder: String

    let text: Binding<String>

    let secure: Bool

    public init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self.text = text
        self.secure = false
    }

    init(placeholder: String, text: Binding<String>, secure: Bool) {
        self.placeholder = placeholder
        self.text = text
        self.secure = secure
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let graph = context.graph
        let id = graph.nextNodeID()
        let text = self.text
        graph.on(id, .change) { payload in
            if let value = payload?.string { text.wrappedValue = value }
        }
        if let onSubmit = context.onSubmit {
            graph.on(id, .submit) { _ in onSubmit() }
        }
        var props: [String: PropValue] = ["text": .string(text.wrappedValue), "placeholder": .string(placeholder)]
        if secure {
            props["secure"] = .bool(true)
        }
        nodes.append(RenderNode("TextField", id: id, props: props))
    }
}

public struct SecureField: View {

    let field: TextField

    public init(_ placeholder: String, text: Binding<String>) {
        self.field = TextField(placeholder: placeholder, text: text, secure: true)
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        field._render(into: &nodes, context: context)
    }
}

public struct Slider: View {

    let value: Binding<Double>

    let bounds: ClosedRange<Double>

    let step: Double?

    public init(value: Binding<Double>, in bounds: ClosedRange<Double> = 0...1, step: Double? = nil) {
        self.value = value
        self.bounds = bounds
        self.step = step
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let graph = context.graph
        let id = graph.nextNodeID()
        let value = self.value
        let bounds = self.bounds
        graph.on(id, .change) { payload in
            if let new = payload?.double {
                value.wrappedValue = Swift.min(bounds.upperBound, Swift.max(bounds.lowerBound, new))
            }
        }
        var props: [String: PropValue] = [
            "value": .double(value.wrappedValue),
            "min": .double(bounds.lowerBound),
            "max": .double(bounds.upperBound),
        ]
        if let step {
            props["step"] = .double(step)
        }
        nodes.append(RenderNode("Slider", id: id, props: props))
    }
}

public struct Stepper<Label: View>: View {

    let value: Binding<Int>

    let bounds: ClosedRange<Int>

    let step: Int

    let label: Label

    public init(value: Binding<Int>, in bounds: ClosedRange<Int> = Int.min...Int.max, step: Int = 1, @ViewBuilder label: () -> Label) {
        self.value = value
        self.bounds = bounds
        self.step = step
        self.label = label()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let graph = context.graph
        let id = graph.nextNodeID()
        let value = self.value
        let bounds = self.bounds
        graph.on(id, .change) { payload in
            if let new = payload?.int {
                value.wrappedValue = Swift.min(bounds.upperBound, Swift.max(bounds.lowerBound, new))
            }
        }
        nodes.append(RenderNode("Stepper", id: id, props: [
            "value": .int(value.wrappedValue),
            "min": .int(bounds.lowerBound),
            "max": .int(bounds.upperBound),
            "step": .int(step),
        ], children: context.children(label)))
    }
}

extension Stepper where Label == Text {

    public init(_ title: String, value: Binding<Int>, in bounds: ClosedRange<Int> = Int.min...Int.max, step: Int = 1) {
        self.init(value: value, in: bounds, step: step) { Text(title) }
    }
}

/// Progress toward `total`, or indeterminate without a value.
public struct ProgressView: View {

    let value: Double?

    let total: Double

    let title: String?

    public init() {
        self.value = nil
        self.total = 1
        self.title = nil
    }

    public init(value: Double?, total: Double = 1) {
        self.value = value
        self.total = total
        self.title = nil
    }

    public init(_ title: String, value: Double? = nil, total: Double = 1) {
        self.value = value
        self.total = total
        self.title = title
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        var props: [String: PropValue] = ["total": .double(total)]
        if let value {
            props["value"] = .double(value)
        }
        if let title {
            props["title"] = .string(title)
        }
        nodes.append(context.node("ProgressView", props: props))
    }
}

// MARK: - Menu

/// A button that shows a menu of actions: `Button`s, `Divider`s, `Section`s
/// and other menus.
///
/// A `Menu` node has its label's `title` and `systemImage`, and its items as
/// children. The items report their own events.
public struct Menu<Label: View, Content: View>: View {

    let label: Label

    let content: Content

    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content()
        self.label = label()
    }

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        let id = context.graph.nextNodeID()
        var itemContext = context
        itemContext.items = nil
        let props = itemProps(itemContext.children(label))
        nodes.append(RenderNode("Menu", id: id, props: props, children: itemContext.children(content)))
    }
}

extension Menu where Label == Text {

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content) { Text(title) }
    }
}

/// `Label`, where a generic parameter named `Label` hides it. Guest builds
/// name this module `SwiftUI`, so it can't be qualified.
public typealias _LabelView = Label

extension Menu where Label == _LabelView {

    public init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.init(content: content) { _LabelView(title, systemImage: systemImage) }
    }
}
