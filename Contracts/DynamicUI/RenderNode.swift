/// A leaf value in a node's props or a modifier's arguments (§9.2).
public enum PropValue: Equatable, Sendable {
    case string(String)
    case double(Double)
    case bool(Bool)
    case int(Int)
    case array([PropValue])
}

extension PropValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension PropValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension PropValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension PropValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

public extension PropValue {

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var double: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var int: Int? {
        if case .int(let value) = self { return value }
        return nil
    }
}

/// One entry in a node's modifier chain. Order is significant:
/// `.padding().background(.red)` pads, then fills the padded area.
public struct ModifierNode: Equatable, Sendable {

    /// Modifier kind: "padding", "frame", "font", … A host ignores kinds it
    /// doesn't know.
    public var kind: String

    public var args: [String: PropValue]

    public init(_ kind: String, _ args: [String: PropValue] = [:]) {
        self.kind = kind
        self.args = args
    }
}

/// A node of the resolved view tree a guest sends its renderer (§9.2).
public struct RenderNode: Equatable, Sendable {

    /// Structural identity: stable across re-evaluation while the view keeps
    /// its place in the tree, so a host can key native views to it.
    public typealias ID = UInt64

    /// Primitive kind: "Text", "VStack", "Button", … A host renders a type it
    /// doesn't know as an empty placeholder.
    public var type: String

    public var id: ID

    public var props: [String: PropValue]

    public var modifiers: [ModifierNode]

    /// Eagerly resolved children.
    public var children: [RenderNode]

    /// For a lazy container: how many rows it has. The host asks for the ones
    /// it shows with `RendererDelegate.row`. `nil` for eager nodes.
    public var count: Int?

    public init(
        _ type: String,
        id: ID,
        props: [String: PropValue] = [:],
        modifiers: [ModifierNode] = [],
        children: [RenderNode] = [],
        count: Int? = nil
    ) {
        self.type = type
        self.id = id
        self.props = props
        self.modifiers = modifiers
        self.children = children
        self.count = count
    }

    /// The first node with `id` in this subtree, depth first.
    public func node(_ id: ID) -> RenderNode? {
        if self.id == id { return self }
        for child in children {
            if let found = child.node(id) { return found }
        }
        return nil
    }

    /// Replaces the node with `id` in this subtree. Returns whether it was found.
    @discardableResult
    public mutating func replace(_ id: ID, with node: RenderNode) -> Bool {
        if self.id == id {
            self = node
            return true
        }
        for index in children.indices where children[index].replace(id, with: node) {
            return true
        }
        return false
    }
}

/// What a host reports through `RendererDelegate.event` (§9.3).
public enum RenderEventKind: Int32, Sendable {

    /// A button, link or `onTapGesture`. No payload.
    case tap = 1

    /// A control's new value: a toggle's bool, a field's string, a slider's
    /// double, a stepper's int.
    case change = 2

    /// Return in a text field. No payload.
    case submit = 3

    /// Back navigation in a `NavStack`: the payload is the int number of
    /// levels left.
    case pop = 4

    /// Pull to refresh on a `Refreshable` node. No payload. The node's
    /// `refreshing` prop is true until the guest finishes.
    case refresh = 5

    /// The keyboard came to, or left, a view with a `focused` modifier:
    /// the payload is a bool, whether it has it now.
    case focus = 6

    /// The window's values changed, sent to node ID 0: the payload is
    /// `RenderEnvironment.payload`, with every value the host knows.
    case environment = 7

    /// Where a `Map` looks, after the user moved it: the payload is
    /// `[lat, lon, distance, heading, pitch, latitudeDelta, longitudeDelta]`.
    case camera = 8

    /// A long press on a `Map`, away from its content: the payload is the
    /// coordinate, `[lat, lon]`. On a view with `longPressGesture`, no
    /// payload.
    case longPress = 9

    /// A drag on a view with `dragGesture`: the payload is `[phase, startX,
    /// startY, x, y, predictedEndX, predictedEndY]`, `phase` 0 changed, 1
    /// ended, 2 cancelled.
    case drag = 10

    /// A long press began touching, or stopped: a bool.
    case pressing = 11

    /// The user dragged a sheet to another detent: the payload is its int
    /// index, sent to the `Sheet` node.
    case detent = 12
}

extension RenderNode {

    /// The window, for `environment` events. No node has this ID.
    public static let windowID: ID = 0
}
