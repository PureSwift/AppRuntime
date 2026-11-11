#if !EMBEDDED_NO_CONCURRENCY
#if hasFeature(Embedded)
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// Waits for one delegate callback: the one-shot half of the async wrappers
/// over provider contracts (§6.2.1).
///
/// `start` registers the callback where the delegate will find it and makes
/// the contract call. The delegate resumes it with a value or an error. If
/// the task is cancelled first, `onCancel` decides what happens: typically
/// it cancels the native operation and resumes with a cancellation error.
/// The callback may also be resumed during `start`. Both closures run on the
/// guest's one thread (§6.4), so neither has to be `@Sendable`.
///
/// Typed throws, so it works in Embedded Swift, which has no `any Error`
/// values (and so no `withCheckedThrowingContinuation`).
public func withCallback<Value, Failure: Error>(
    _ start: (Callback<Value, Failure>) -> Void,
    onCancel: @escaping (Callback<Value, Failure>) -> Void
) async throws(Failure) -> Value {
    let callback = Callback<Value, Failure>()
    let cancel = Transfer(onCancel)
    let result = await withTaskCancellationHandler {
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Transfer<Result<Value, Failure>>, Never>) in
            callback.attach(continuation)
            if !callback.isResolved {
                start(callback)
            }
        }
    } onCancel: {
        cancel.value(callback)
    }
    return try result.value.get()
}

/// The pending result of `withCallback`. The first `resume` wins; later
/// ones are ignored, so a late delegate callback after a cancellation is
/// harmless. The guest is single-threaded (§6.4).
public final class Callback<Value, Failure: Error>: @unchecked Sendable {

    private var continuation: UnsafeContinuation<Transfer<Result<Value, Failure>>, Never>?

    private var result: Result<Value, Failure>?

    init() { }

    /// Whether it has been resumed.
    public var isResolved: Bool {
        result != nil
    }

    public func resume(returning value: Value) {
        resume(with: .success(value))
    }

    public func resume(throwing error: Failure) {
        resume(with: .failure(error))
    }

    public func resume(with result: Result<Value, Failure>) {
        guard self.result == nil else { return }
        self.result = result
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: Transfer(result))
        }
    }

    func attach(_ continuation: UnsafeContinuation<Transfer<Result<Value, Failure>>, Never>) {
        if let result {
            continuation.resume(returning: Transfer(result))
        } else {
            self.continuation = continuation
        }
    }
}

/// Carries a value across a continuation. Delegate callbacks and the tasks
/// waiting on them all run on the guest's one thread (§6.4), which the
/// compiler can't see.
struct Transfer<Value>: @unchecked Sendable {

    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

public extension Callback where Value == Void {

    func resume() {
        resume(returning: ())
    }
}
#endif
