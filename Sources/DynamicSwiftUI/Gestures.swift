import DynamicUI

/// Where a gesture's positions are measured: the view's own bounds, or the
/// window's.
public enum CoordinateSpace: String, Sendable {
    case local
    case global
}

/// What SwiftUI passes alongside a gesture's state. Kept for the signature
/// of `updating(_:body:)`; it carries nothing here.
public struct Transaction: Sendable {
    public init() { }
}

/// A gesture a view recognizes: a drag, a long press, a tap. Attach one
/// with `gesture(_:)`.
///
/// The host recognizes it as its platform does, and tells a tap, a long
/// press and a drag on the same view apart by the platform's own rules.
/// The guest hears what it recognized.
public protocol Gesture {

    associatedtype Value

    /// The modifier that asks the host for it.
    var _modifier: ModifierNode { get }

    /// Registers the gesture's events on the node.
    func _register(_ node: RenderNode.ID, graph: ViewGraph)
}

/// A value a gesture sets while it lasts, through `updating(_:body:)`, that
/// goes back to its first value when the gesture ends, however it ends.
@propertyWrapper
public struct GestureState<Value> {

    let box: StateBox<Value>

    let initial: Value

    public init(wrappedValue value: Value) {
        initial = value
        if let graph = ViewGraph.current, graph.isEvaluating {
            box = graph.stateBox { value }
        } else {
            box = StateBox(value)
        }
    }

    public init(initialValue value: Value) {
        self.init(wrappedValue: value)
    }

    public var wrappedValue: Value {
        box.value
    }

    /// What `updating(_:body:)` takes: `$isPressing`.
    public var projectedValue: GestureState<Value> {
        self
    }

    func reset() {
        box.value = initial
    }
}

/// The closures a gesture calls, and the gesture states it resets.
struct GestureCallbacks<Value> {

    var changed: [(Value) -> Void] = []

    var ended: [(Value) -> Void] = []

    /// Each `updating`: sets its state from the value.
    var updates: [(Value) -> Void] = []

    var resets: [() -> Void] = []

    func change(_ value: Value) {
        for update in updates { update(value) }
        for action in changed { action(value) }
    }

    func end(_ value: Value) {
        for action in ended { action(value) }
        reset()
    }

    func reset() {
        for reset in resets { reset() }
    }

    mutating func updating<State>(_ state: GestureState<State>, _ body: @escaping (Value, inout State, inout Transaction) -> Void) {
        let box = state.box
        updates.append { value in
            var current = box.value
            var transaction = Transaction()
            body(value, &current, &transaction)
            box.value = current
        }
        resets.append { state.reset() }
    }
}

// MARK: - Drag

/// A finger, or the pointer, moving across a view: SwiftUI's
/// `DragGesture`. It begins once it has moved `minimumDistance` points.
public struct DragGesture: Gesture {

    public struct Value: Equatable, Sendable {

        public var startLocation: Point

        public var location: Point

        public var predictedEndLocation: Point

        public var translation: Size {
            Size(width: location.x - startLocation.x, height: location.y - startLocation.y)
        }

        public var predictedEndTranslation: Size {
            Size(width: predictedEndLocation.x - startLocation.x, height: predictedEndLocation.y - startLocation.y)
        }

        public init(startLocation: Point, location: Point, predictedEndLocation: Point) {
            self.startLocation = startLocation
            self.location = location
            self.predictedEndLocation = predictedEndLocation
        }
    }

    public var minimumDistance: Double

    public var coordinateSpace: CoordinateSpace

    var callbacks = GestureCallbacks<Value>()

    public init(minimumDistance: Double = 10, coordinateSpace: CoordinateSpace = .local) {
        self.minimumDistance = minimumDistance
        self.coordinateSpace = coordinateSpace
    }

    /// Called as it moves, at most once a frame.
    public func onChanged(_ action: @escaping (Value) -> Void) -> DragGesture {
        var gesture = self
        gesture.callbacks.changed.append(action)
        return gesture
    }

    /// Called once when the finger lifts. A drag the system takes away ends
    /// without it.
    public func onEnded(_ action: @escaping (Value) -> Void) -> DragGesture {
        var gesture = self
        gesture.callbacks.ended.append(action)
        return gesture
    }

    public func updating<State>(_ state: GestureState<State>, body: @escaping (Value, inout State, inout Transaction) -> Void) -> DragGesture {
        var gesture = self
        gesture.callbacks.updating(state, body)
        return gesture
    }

    public var _modifier: ModifierNode {
        ModifierNode("dragGesture", [
            "minimumDistance": .double(minimumDistance),
            "coordinateSpace": .string(coordinateSpace.rawValue),
        ])
    }

    public func _register(_ node: RenderNode.ID, graph: ViewGraph) {
        let callbacks = self.callbacks
        graph.on(node, .drag) { payload in
            guard case .array(let items)? = payload, items.count >= 7 else { return }
            let numbers = items.map { item -> Double in
                switch item {
                case .double(let value): return value
                case .int(let value): return Double(value)
                default: return 0
                }
            }
            let value = Value(
                startLocation: Point(x: numbers[1], y: numbers[2]),
                location: Point(x: numbers[3], y: numbers[4]),
                predictedEndLocation: Point(x: numbers[5], y: numbers[6])
            )
            switch numbers[0] {
            case 0: callbacks.change(value)
            case 1: callbacks.end(value)
            default: callbacks.reset()
            }
        }
    }
}

// MARK: - Long press

/// A touch held still: SwiftUI's `LongPressGesture`. Its value is whether
/// it's pressing: true while `updating` hears it, and when it ends.
public struct LongPressGesture: Gesture {

    public typealias Value = Bool

    public var minimumDuration: Double

    public var maximumDistance: Double

    var callbacks = GestureCallbacks<Bool>()

    var pressing: [(Bool) -> Void] = []

    public init(minimumDuration: Double = 0.5, maximumDistance: Double = 10) {
        self.minimumDuration = minimumDuration
        self.maximumDistance = maximumDistance
    }

    /// Called once the press has lasted `minimumDuration`.
    public func onEnded(_ action: @escaping (Bool) -> Void) -> LongPressGesture {
        var gesture = self
        gesture.callbacks.ended.append(action)
        return gesture
    }

    /// Called with true while a touch is down, and false when it lifts.
    public func updating<State>(_ state: GestureState<State>, body: @escaping (Bool, inout State, inout Transaction) -> Void) -> LongPressGesture {
        var gesture = self
        gesture.callbacks.updating(state, body)
        return gesture
    }

    func onPressingChanged(_ action: @escaping (Bool) -> Void) -> LongPressGesture {
        var gesture = self
        gesture.pressing.append(action)
        return gesture
    }

    public var _modifier: ModifierNode {
        var args: [String: PropValue] = [
            "minimumDuration": .double(minimumDuration),
            "maximumDistance": .double(maximumDistance),
        ]
        if !pressing.isEmpty || !callbacks.updates.isEmpty {
            args["pressing"] = .bool(true)
        }
        return ModifierNode("longPressGesture", args)
    }

    public func _register(_ node: RenderNode.ID, graph: ViewGraph) {
        let callbacks = self.callbacks
        let pressing = self.pressing
        graph.on(node, .longPress) { _ in
            callbacks.end(true)
        }
        graph.on(node, .pressing) { payload in
            let isPressing = payload?.bool ?? false
            for action in pressing { action(isPressing) }
            if isPressing {
                callbacks.change(true)
            } else {
                callbacks.reset()
            }
        }
    }
}

// MARK: - Tap

/// A tap, or several: the same as `onTapGesture(count:)`.
public struct TapGesture: Gesture {

    public typealias Value = Void

    public var count: Int

    var ended: [() -> Void] = []

    public init(count: Int = 1) {
        self.count = count
    }

    public func onEnded(_ action: @escaping () -> Void) -> TapGesture {
        var gesture = self
        gesture.ended.append(action)
        return gesture
    }

    public var _modifier: ModifierNode {
        ModifierNode("onTapGesture", ["count": .int(count)])
    }

    public func _register(_ node: RenderNode.ID, graph: ViewGraph) {
        let ended = self.ended
        graph.on(node, .tap) { _ in
            for action in ended { action() }
        }
    }
}

// MARK: - Attaching

extension View {

    /// Recognizes `gesture` on this view.
    public func gesture<G: Gesture>(_ gesture: G) -> _ModifierView<Self> {
        _ModifierView(content: self, modifier: gesture._modifier) { id, graph in
            gesture._register(id, graph: graph)
        }
    }

    /// Runs `action` once a touch has stayed on the view for
    /// `minimumDuration` seconds without moving more than `maximumDistance`
    /// points. `onPressingChanged` hears true when a touch begins and false
    /// when it ends.
    public func onLongPressGesture(
        minimumDuration: Double = 0.5,
        maximumDistance: Double = 10,
        perform action: @escaping () -> Void,
        onPressingChanged: ((Bool) -> Void)? = nil
    ) -> _ModifierView<Self> {
        var gesture = LongPressGesture(minimumDuration: minimumDuration, maximumDistance: maximumDistance)
            .onEnded { _ in action() }
        if let onPressingChanged {
            gesture = gesture.onPressingChanged(onPressingChanged)
        }
        return self.gesture(gesture)
    }
}
