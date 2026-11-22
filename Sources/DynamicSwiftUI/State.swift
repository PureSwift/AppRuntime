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
