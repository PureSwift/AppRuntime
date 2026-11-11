import DynamicUI
#if canImport(DynamicObservation)
@_exported import DynamicObservation
#else
@_exported import Observation
#endif

/// Storage for one `@State` value. Observable, so a view that reads it
/// updates when it changes.
final class StateBox<Value>: Observable {

    private let registrar = ObservationRegistrar()

    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    var value: Value {
        get {
            registrar.access(self, propertyIndex: 0)
            return storage
        }
        set {
            registrar.withMutation(of: self, propertyIndex: 0) {
                storage = newValue
            }
        }
    }
}

/// A value a view owns, which survives updates. Matched to the view by
/// position (see `ViewGraph`).
@propertyWrapper
public struct State<Value> {

    let box: StateBox<Value>

    public init(wrappedValue value: Value) {
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
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    public var projectedValue: Binding<Value> {
        let box = self.box
        return Binding(get: { box.value }, set: { box.value = $0 })
    }
}

extension State where Value: ExpressibleByNilLiteral {

    public init() {
        self.init(wrappedValue: nil)
    }
}

/// Bindings to an `@Observable` model's properties: `$model.name`.
///
/// Without key paths (§5.3), `projectedValue` is the `Bindings` value that
/// `@Observable` generates, with one `Binding` per stored property that has
/// a type annotation.
@propertyWrapper
public struct Bindable<Value: _BindableObservable> {

    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    public init(_ wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    public var projectedValue: Value.Bindings {
        wrappedValue._$bindings
    }
}

// MARK: - ObservableObject

/// An object whose `@Published` properties update the views that use it.
/// Kept for code from older SwiftUI (§5.3); there is no Combine, so a change
/// updates every view graph.
public protocol ObservableObject: AnyObject { }

/// A property of an `ObservableObject` that updates views when it changes.
@propertyWrapper
public struct Published<Value> {

    var value: Value

    public init(wrappedValue value: Value) {
        self.value = value
    }

    public init(initialValue value: Value) {
        self.init(wrappedValue: value)
    }

    public var wrappedValue: Value {
        get { value }
        set {
            value = newValue
            ViewGraph.setAllNeedUpdate()
        }
    }
}

/// An `ObservableObject` passed to a view by its parent.
@propertyWrapper
public struct ObservedObject<ObjectType: ObservableObject> {

    public var wrappedValue: ObjectType

    public init(wrappedValue: ObjectType) {
        self.wrappedValue = wrappedValue
    }
}

/// An `ObservableObject` a view makes once and keeps, matched by position
/// like `@State`.
@propertyWrapper
public struct StateObject<ObjectType: ObservableObject> {

    let box: StateBox<ObjectType>

    public init(wrappedValue: @autoclosure () -> ObjectType) {
        if let graph = ViewGraph.current, graph.isEvaluating {
            box = graph.stateBox(wrappedValue)
        } else {
            box = StateBox(wrappedValue())
        }
    }

    public var wrappedValue: ObjectType {
        box.value
    }
}

// MARK: - Environment

/// Finds an object an ancestor put in the environment. Resolved when the
/// view is made during an update, or on first use while rendering, and kept,
/// so actions and tasks that run later still see it.
final class EnvironmentStorage<Object: AnyObject> {

    var object: Object?

    func resolve() -> Object? {
        if let object { return object }
        object = ViewGraph.current?.contexts.last?.object(Object.self)
        return object
    }
}

/// An `ObservableObject` from an ancestor's `environmentObject(_:)`.
@propertyWrapper
public struct EnvironmentObject<ObjectType: ObservableObject> {

    let storage = EnvironmentStorage<ObjectType>()

    public init() {
        _ = storage.resolve()
    }

    public var wrappedValue: ObjectType {
        guard let object = storage.resolve() else {
            fatalError("No ObservableObject of this type found. A View.environmentObject(_:) for it may be missing as an ancestor of this view.")
        }
        return object
    }
}

/// An `@Observable` object from an ancestor's `environment(_:)`:
/// `@Environment(Model.self) var model`. The key-path form
/// (`@Environment(\.colorScheme)`) needs key paths, which Embedded Swift
/// doesn't have.
@propertyWrapper
public struct Environment<Value: AnyObject> {

    let storage = EnvironmentStorage<Value>()

    public init(_ type: Value.Type) {
        _ = storage.resolve()
    }

    public var wrappedValue: Value {
        guard let object = storage.resolve() else {
            fatalError("No object of this type found. A View.environment(_:) for it may be missing as an ancestor of this view.")
        }
        return object
    }
}

/// A view whose descendants see a changed `RenderContext`.
public struct _EnvironmentView<Content: View>: View {

    let content: Content

    let transform: (inout RenderContext) -> Void

    public var body: Never {
        fatalError()
    }

    public func _render(into nodes: inout [RenderNode], context: RenderContext) {
        var context = context
        transform(&context)
        content._render(into: &nodes, context: context)
    }
}

extension View {

    /// Makes `object` available to `@EnvironmentObject` in descendants.
    public func environmentObject<T: ObservableObject>(_ object: T) -> _EnvironmentView<Self> {
        _EnvironmentView(content: self) { $0.objects.append((ObjectIdentifier(T.self), object)) }
    }

    /// Makes an `@Observable` object available to `@Environment(T.self)` in
    /// descendants.
    public func environment<T: Observable & AnyObject>(_ object: T) -> _EnvironmentView<Self> {
        _EnvironmentView(content: self) { $0.objects.append((ObjectIdentifier(T.self), object)) }
    }
}
