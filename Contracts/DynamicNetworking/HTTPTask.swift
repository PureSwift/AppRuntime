import DynamicRuntime

/// A request in flight.
@DynamicRuntime("org.pureswift.network.HTTPTask")
public protocol HTTPTask: AnyObject {

    /// Cancels the request; the delegate gets `didComplete` with
    /// `NetworkError.cancelled`.
    func cancel()

    /// An `HTTPTaskState` raw value.
    func state() -> Int32
}
