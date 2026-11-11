import RuntimeABI
#if hasFeature(Embedded) && !EMBEDDED_NO_CONCURRENCY
// Embedded Swift doesn't import the concurrency module implicitly.
import _Concurrency
#endif

/// The built-in `Clock` contract (§5.4): monotonic time and one-shot timers.
///
/// Embedded Swift has no clocks and no `Task.sleep`, so this is the guest's
/// source of time. Every host provides it. Timers fire on the main thread,
/// through `rt_dispatch`.
public enum RuntimeClock {

    /// Contract name.
    public static let name: StaticString = "org.pureswift.runtime.Clock"

    /// The callback interface a timer fires.
    public static let delegateName: StaticString = "org.pureswift.runtime.ClockDelegate"

    public static let classReference = ClassReference(name)

    public static let delegateReference = ClassReference(delegateName)

    public static let nowMethod = MethodReference(classReference, "now", "()J", .static)

    public static let afterMethod = MethodReference(classReference, "after:delegate:", "(JO)V", .static)

    /// The contract descriptor hosts register.
    public static var descriptor: ContractDescriptor {
        BuiltinContracts.clock
    }

    /// The callback descriptor hosts register.
    public static var delegateDescriptor: ContractDescriptor {
        BuiltinContracts.clockDelegate
    }

    /// Monotonic nanoseconds since an arbitrary start.
    public static func now() throws(RuntimeError) -> Int64 {
        try Call(nowMethod).invoke().scalar(Int64.self)
    }

    /// Calls `body` once, after at least `nanoseconds`, when the host's
    /// timer fires. Each timer is a `ClockDelegate` the host holds until then.
    public static func after(nanoseconds: Int64, _ body: @escaping () -> Void) throws(RuntimeError) {
        let timer = ClockTimer(body)
        let handle = Exported.implement(
            timer,
            interface: delegateReference,
            descriptor: delegateDescriptor
        ) { (_: UInt32, _: ObjectHandle, _: inout Arguments, _: ResultWriter) throws(RuntimeError) in
            timer.fire()
        }
        guard handle != 0 else {
            throw .notFound
        }
        var call = Call(afterMethod)
        call.add(nanoseconds)
        // The host retains the delegate; ours is released after the call.
        call.add(retained: handle)
        _ = try call.invoke()
    }

    #if !EMBEDDED_NO_CONCURRENCY
    /// Suspends the current task for at least `nanoseconds`, the Embedded
    /// stand-in for `Task.sleep`. Throws `CancellationError` if the task is
    /// cancelled first. Traps if the host has no clock.
    public static func sleep(nanoseconds: Int64) async throws(CancellationError) {
        let sleeper = Sleeper()
        let completed = await withTaskCancellationHandler {
            await withUnsafeContinuation { (continuation: UnsafeContinuation<Bool, Never>) in
                sleeper.start(continuation, nanoseconds: nanoseconds)
            }
        } onCancel: {
            sleeper.finish(completed: false)
        }
        guard completed else {
            throw CancellationError()
        }
    }
    #endif
}

/// One `Clock` timer, exported as a `ClockDelegate`. The export keeps it
/// alive until the host releases the delegate.
private final class ClockTimer {

    private var body: (() -> Void)?

    init(_ body: @escaping () -> Void) {
        self.body = body
    }

    /// Runs the body the first time only.
    func fire() {
        let body = self.body
        self.body = nil
        body?()
    }
}

#if !EMBEDDED_NO_CONCURRENCY
/// Resumes a sleeping task once: when its timer fires, or when it's
/// cancelled, whichever comes first. The guest is single-threaded (§6.4).
private final class Sleeper: @unchecked Sendable {

    private var continuation: UnsafeContinuation<Bool, Never>?

    private var cancelled = false

    func start(_ continuation: UnsafeContinuation<Bool, Never>, nanoseconds: Int64) {
        // Cancelled before the task suspended.
        if cancelled {
            continuation.resume(returning: false)
            return
        }
        self.continuation = continuation
        do throws(RuntimeError) {
            try RuntimeClock.after(nanoseconds: nanoseconds) { [self] in
                finish(completed: true)
            }
        } catch {
            fatalError("Clock.after failed: \(error.message)")
        }
    }

    func finish(completed: Bool) {
        guard let continuation else {
            if !completed {
                cancelled = true
            }
            return
        }
        self.continuation = nil
        continuation.resume(returning: completed)
    }
}
#endif
