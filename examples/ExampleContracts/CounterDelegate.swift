import DynamicRuntime

/// Implemented by the app; the host's counter calls back through it.
@DynamicCallback("org.pureswift.example.CounterDelegate")
public protocol CounterDelegate: AnyObject {

    func didChange(_ counter: Counter, value: Int64)

    /// Synchronous request answered by the guest.
    func shouldIncrement(_ counter: Counter, by amount: Int32) -> Bool

    func didReset(_ counter: Counter)
}
