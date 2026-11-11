/// A reference to a value owned elsewhere: SwiftUI's `Binding`.
///
/// It lives in the Observation stopgap rather than SwiftUI so the `Bindings`
/// that `@Observable` generates compile in files that don't import SwiftUI.
/// SwiftUI re-exports it.
@propertyWrapper
public struct Binding<Value> {

    private let read: () -> Value

    private let write: (Value) -> Void

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.read = get
        self.write = set
    }

    /// For `@Binding var value: Value` properties initialized from a binding.
    public init(projectedValue: Binding<Value>) {
        self = projectedValue
    }

    /// A binding that ignores writes.
    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { _ in })
    }

    public var wrappedValue: Value {
        get { read() }
        nonmutating set { write(newValue) }
    }

    public var projectedValue: Binding<Value> {
        self
    }
}
