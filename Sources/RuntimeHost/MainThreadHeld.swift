/// A reference to one of the runtime's objects, such as a callback or a
/// delegate, for work on another thread to carry back to the main thread
/// without touching it.
///
/// The runtime's objects belong to the main thread (§6.4), and that
/// includes releasing them: a proxy's last release tells the runtime, which
/// isn't thread-safe. A closure that captures a proxy and runs on a queue
/// releases it there when the closure is destroyed, and that's the last
/// release whenever the main thread has finished with it first. So the
/// closure captures one of these instead, and the main thread takes the
/// object out:
///
/// ```swift
/// let held = MainThreadHeld(callback)
/// queue.async {
///     let answer = work()
///     DispatchQueue.main.async {
///         held.take()?.didComplete(answer)
///     }
/// }
/// ```
///
/// What's left to be destroyed on the queue is empty.
public final class MainThreadHeld<Value>: @unchecked Sendable {

    private var value: Value?

    /// Call on the main thread.
    public init(_ value: Value) {
        self.value = value
    }

    /// The object, which is the caller's from here on, to use and release.
    /// `nil` the second time. Call on the main thread.
    public func take() -> Value? {
        defer { value = nil }
        return value
    }
}
